using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>The kinds of notice that can show at the top of the panel, in the order they show.</summary>
public enum BannerKind
{
    /// <summary>The last hosts file check failed.</summary>
    HostsWarning,
    /// <summary>Password checks are paused after too many wrong passwords.</summary>
    Lockout,
    /// <summary>A shorter unblock delay has been asked for.</summary>
    DelayChange,
    /// <summary>An uninstall is scheduled.</summary>
    Uninstall,
    /// <summary>A password reset is running.</summary>
    Recovery,
    /// <summary>A newer SiteBlock is available.</summary>
    Update,
}

/// <summary>The color of a banner's box and icon.</summary>
public enum BannerTint
{
    /// <summary>Something is wrong or will be removed.</summary>
    Red,
    /// <summary>Something is waiting.</summary>
    Orange,
    /// <summary>Information (an update).</summary>
    Blue,
}

/// <summary>What a banner button does.</summary>
public enum BannerActionKind
{
    /// <summary>"Keep current delay": drops the requested shorter delay.</summary>
    CancelDelayChange,
    /// <summary>"Cancel uninstall".</summary>
    CancelUninstall,
    /// <summary>"Cancel reset".</summary>
    CancelRecovery,
    /// <summary>"Update": starts the install.</summary>
    InstallUpdate,
    /// <summary>"Not now": hides the update banner for this build.</summary>
    DismissUpdate,
}

/// <summary>One banner button.</summary>
/// <param name="Kind">What it does.</param>
/// <param name="Label">Its words.</param>
/// <param name="Prominent">True for the filled main button ("Update").</param>
/// <param name="DisabledWhileBusy">True when the button is off while a command waits for the service.</param>
public sealed record BannerAction(BannerActionKind Kind, string Label, bool Prominent = false, bool DisabledWhileBusy = true);

/// <summary>One banner as it shows right now.</summary>
/// <param name="Kind">Which notice it is.</param>
/// <param name="Tint">Its color.</param>
/// <param name="Text">The main sentence, with any live countdown filled in.</param>
/// <param name="StepText">For the update banner while an install runs: the step, shown with a spinner in place of the buttons. Null otherwise.</param>
/// <param name="ErrorText">For the update banner after a failure: the failure sentence in red. Null otherwise.</param>
/// <param name="NoticeText">For the update banner after a cancelled UAC prompt: "The update was cancelled." in gray. Null otherwise.</param>
/// <param name="Actions">The buttons, in order; empty while an install step shows.</param>
public sealed record Banner(BannerKind Kind, BannerTint Tint, string Text, string? StepText, string? ErrorText, string? NoticeText, IReadOnlyList<BannerAction> Actions)
{
    /// <summary>True when both banners show the same thing, comparing the button lists entry by entry.</summary>
    public bool Equals(Banner? other) =>
        other is not null && Kind == other.Kind && Tint == other.Tint && Text == other.Text && StepText == other.StepText && ErrorText == other.ErrorText && NoticeText == other.NoticeText && Actions.SequenceEqual(other.Actions);

    /// <summary>A hash that agrees with <see cref="Equals(Banner?)"/>.</summary>
    public override int GetHashCode() => HashCode.Combine(Kind, Text, StepText, ErrorText, NoticeText, Actions.Count);
}

/// <summary>Works out which banners show and what they say, and carries out their buttons. There is no browser-permission banner on Windows, because UI Automation needs no permission.</summary>
public static class Banners
{
    /// <summary>The hosts file warning.</summary>
    public const string HostsWarningText = "SiteBlock could not confirm that the hosts file is correct. Some sites may not be blocked right now.";

    /// <summary>True when at least one banner or banner message would show, so the panel can leave the banner area out entirely when there is none.</summary>
    public static bool HasContent(StatusSnapshot snapshot, Feedback? feedback, bool updateVisible)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        return updateVisible || !snapshot.HostsFileHealthy || snapshot.LockoutSecondsRemaining is not null || snapshot.PendingDelay is not null
            || snapshot.UninstallSecondsRemaining is not null || snapshot.RecoverySecondsRemaining is not null || feedback?.Scope == FeedbackScope.Banner;
    }

    /// <summary>
    /// The banners to show for a status, in order. <paramref name="remaining"/> turns a reported number of seconds into the live seconds left (see <see cref="StatusModel.Remaining"/>).
    /// The update banner shows while <paramref name="updater"/> says so; it carries the install step, the failure sentence or the cancel notice.
    /// </summary>
    public static IReadOnlyList<Banner> Build(StatusSnapshot snapshot, Func<long, int> remaining, Updater? updater)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(remaining);
        var banners = new List<Banner>();
        if (!snapshot.HostsFileHealthy) banners.Add(Plain(BannerKind.HostsWarning, BannerTint.Red, HostsWarningText));
        if (snapshot.LockoutSecondsRemaining is { } lockout)
        {
            banners.Add(Plain(BannerKind.Lockout, BannerTint.Orange, $"Too many wrong passwords. Password checks resume in {Formatting.Clock(remaining(lockout))}."));
        }
        if (snapshot.PendingDelay is { } change)
        {
            string text = $"The unblock delay changes to {Formatting.Duration(CountdownMath.Clamp(change.NewDelaySeconds))} in {Formatting.Clock(remaining(change.SecondsRemaining))}.";
            banners.Add(Plain(BannerKind.DelayChange, BannerTint.Orange, text, new BannerAction(BannerActionKind.CancelDelayChange, "Keep current delay")));
        }
        if (snapshot.UninstallSecondsRemaining is { } uninstall)
        {
            banners.Add(Plain(BannerKind.Uninstall, BannerTint.Red, $"SiteBlock will uninstall in {Formatting.Clock(remaining(uninstall))}.", new BannerAction(BannerActionKind.CancelUninstall, "Cancel uninstall")));
        }
        if (snapshot.RecoverySecondsRemaining is { } recovery)
        {
            string text = $"A password reset is running. The password will be cleared in {Formatting.Clock(remaining(recovery))}. Blocked sites stay blocked.";
            banners.Add(Plain(BannerKind.Recovery, BannerTint.Orange, text, new BannerAction(BannerActionKind.CancelRecovery, "Cancel reset")));
        }
        if (updater is { ShowsBanner: true, Available: { } info }) banners.Add(UpdateBanner(info, updater));
        return banners;
    }

    /// <summary>The update banner: "SiteBlock 1.0.43 is available." with the running step in place of the buttons, or the buttons with any failure sentence or cancel notice above them.</summary>
    public static Banner UpdateBanner(UpdateInfo info, Updater updater)
    {
        ArgumentNullException.ThrowIfNull(info);
        ArgumentNullException.ThrowIfNull(updater);
        string text = $"SiteBlock {info.ShownVersion} is available.";
        if (updater.Phase.StepText is { } step) return new Banner(BannerKind.Update, BannerTint.Blue, text, step, null, null, []);
        BannerAction[] actions = [new(BannerActionKind.InstallUpdate, "Update", Prominent: true, DisabledWhileBusy: false), new(BannerActionKind.DismissUpdate, "Not now", DisabledWhileBusy: false)];
        return new Banner(BannerKind.Update, BannerTint.Blue, text, null, updater.Phase.FailureText, updater.Notice, actions);
    }

    /// <summary>Carries out a banner button. Call it on the screen's thread.</summary>
    public static Task PerformAsync(StatusModel status, BannerActionKind action)
    {
        ArgumentNullException.ThrowIfNull(status);
        switch (action)
        {
            case BannerActionKind.CancelDelayChange: return status.CancelDelayChangeAsync();
            case BannerActionKind.CancelUninstall: return status.CancelUninstallAsync();
            case BannerActionKind.CancelRecovery: return status.CancelRecoveryAsync();
            case BannerActionKind.InstallUpdate:
                status.Updater?.Install();
                return Task.CompletedTask;
            case BannerActionKind.DismissUpdate:
                status.Updater?.Dismiss();
                return Task.CompletedTask;
            default:
                return Task.CompletedTask;
        }
    }

    /// <summary>A banner with a sentence and optional buttons, and no update parts.</summary>
    private static Banner Plain(BannerKind kind, BannerTint tint, string text, params BannerAction[] actions) => new(kind, tint, text, null, null, null, actions);
}
