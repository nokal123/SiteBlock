using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>
/// The Settings screen: the unblock delay form, the change-password form, the adult filter note, the version and "Check for updates", and the uninstall form. Every form needs the current password, and every password is emptied as soon as its form is submitted.
/// Call its members on the screen's thread.
/// </summary>
public sealed class SettingsModel : ObservableModel
{
    /// <summary>The screen's title.</summary>
    public const string Title = "Settings";
    /// <summary>The delay section's title.</summary>
    public const string DelayTitle = "Unblock delay";
    /// <summary>The label beside the delay picker.</summary>
    public const string DelayLabel = "Wait before a site opens";
    /// <summary>The delay button.</summary>
    public const string ChangeDelayTitle = "Change delay";
    /// <summary>The password section's title.</summary>
    public const string PasswordTitle = "Password";
    /// <summary>The line under the three password fields.</summary>
    public static string PasswordRuleText => $"At least {PasswordHasher.MinimumLength} characters. The new password applies at once.";
    /// <summary>The password button.</summary>
    public const string ChangePasswordTitle = "Change password";
    /// <summary>The complaint when the new password and its confirmation differ.</summary>
    public const string PasswordMismatchText = "The new password and its confirmation are not the same.";
    /// <summary>The adult filter section's title.</summary>
    public const string AdultFilterTitle = "Adult content filter: always on";
    /// <summary>The adult filter section's sentence.</summary>
    public const string AdultFilterText = "Blocks all adult content across every browser and app. To remove it, uninstall SiteBlock.";
    /// <summary>The contact section's title.</summary>
    public const string ContactTitle = "Contact";
    /// <summary>The contact section's sentence, with the email address for comments, questions and ideas.</summary>
    public const string ContactText = "For comments, questions, or ideas, please email nokal123@gmail.com";
    /// <summary>The updates section's title.</summary>
    public const string UpdatesTitle = "Updates";
    /// <summary>The manual check button.</summary>
    public const string CheckForUpdatesTitle = "Check for updates";
    /// <summary>The uninstall section's title.</summary>
    public const string UninstallTitle = "Uninstall";
    /// <summary>The button that opens the uninstall form.</summary>
    public const string UninstallButtonTitle = "Uninstall SiteBlock…";
    /// <summary>The uninstall form's button.</summary>
    public const string StartUninstallTitle = "Start uninstall";
    /// <summary>The sentence shown instead of the uninstall button while an uninstall is scheduled.</summary>
    public const string UninstallScheduledText = "An uninstall is already scheduled. Cancel it from the notice at the top of this screen.";

    /// <summary>The delays the picker offers, in seconds: 5, 15 and 30 minutes, 1, 2, 6, 12 and 24 hours, and 7 days.</summary>
    public static IReadOnlyList<long> DelayChoices { get; } = [300, 900, 1_800, 3_600, 7_200, 21_600, 43_200, 86_400, 604_800];

    private readonly StatusModel _status;
    private long? _pickedDelay;
    private string _delayPassword = "";
    private string _oldPassword = "";
    private string _newPassword = "";
    private string _confirmPassword = "";
    private string? _passwordProblem;
    private bool _confirmingUninstall;
    private string _uninstallPassword = "";
    private bool _focusUninstall;

    /// <summary>Creates the Settings model.</summary>
    public SettingsModel(StatusModel status) => _status = status ?? throw new ArgumentNullException(nameof(status));

    /// <summary>The current delay in force, or 0 before the first status.</summary>
    public long CurrentDelay => _status.Snapshot?.DelaySeconds ?? 0;

    // ---- Delay ----

    /// <summary>The delay picked in the menu, or null while the person has not touched it (meaning the current delay).</summary>
    public long? PickedDelay
    {
        get => _pickedDelay;
        set
        {
            if (SetField(ref _pickedDelay, value)) RaiseDelay();
        }
    }

    /// <summary>The password typed for the delay form.</summary>
    public string DelayPassword
    {
        get => _delayPassword;
        set
        {
            if (SetField(ref _delayPassword, value ?? "")) OnPropertyChanged(nameof(CanChangeDelay));
        }
    }

    /// <summary>The delay the picker shows: the pick, or the current delay.</summary>
    public long ShownDelay => PickedDelay ?? CurrentDelay;

    /// <summary>The picker's entries: the standard choices plus the current delay when it is not one of them (for example 45 minutes set from the command line), sorted.</summary>
    public IReadOnlyList<long> DelayOptions => DelayChoices.Append(CurrentDelay).Distinct().Order().ToList();

    /// <summary>The words for one delay in the picker, such as "30 minutes".</summary>
    public static string DelayLabelFor(long seconds) => Formatting.Duration(CountdownMath.Clamp(seconds));

    /// <summary>The gray line that says what the picked delay will do: a longer one applies at once, a shorter one waits out the current delay first.</summary>
    public string DelayHint
    {
        get
        {
            string current = Formatting.Duration(CountdownMath.Clamp(CurrentDelay));
            if (ShownDelay < CurrentDelay) return $"A shorter delay only starts after the current wait of {current} has passed. You can cancel the change before then.";
            if (ShownDelay > CurrentDelay) return "A longer delay applies right away.";
            return $"Unblocking a site now takes {current}. A longer delay applies right away; a shorter one waits out the current delay first.";
        }
    }

    /// <summary>True when "Change delay" may be pressed: a different delay is picked, a password is typed, and no command waits.</summary>
    public bool CanChangeDelay => ShownDelay != CurrentDelay && DelayPassword.Length > 0 && !_status.IsBusy;

    /// <summary>Sends the picked delay with the typed password, emptying the field first. After a success the picker follows the service's delay again. Returns whether the service accepted it.</summary>
    public async Task<bool> ApplyDelayAsync()
    {
        if (!CanChangeDelay) return false;
        long seconds = ShownDelay;
        string typed = DelayPassword;
        DelayPassword = "";
        bool accepted = await _status.SetDelayAsync(seconds, typed);
        if (accepted) PickedDelay = null;
        return accepted;
    }

    // ---- Password ----

    /// <summary>The "Current password" field.</summary>
    public string OldPassword { get => _oldPassword; set => SetPasswordField(ref _oldPassword, value, clearsProblem: false); }

    /// <summary>The "New password" field. Typing removes an earlier mismatch complaint.</summary>
    public string NewPassword { get => _newPassword; set => SetPasswordField(ref _newPassword, value, clearsProblem: true); }

    /// <summary>The "Confirm new password" field. Typing removes an earlier mismatch complaint.</summary>
    public string ConfirmPassword { get => _confirmPassword; set => SetPasswordField(ref _confirmPassword, value, clearsProblem: true); }

    /// <summary>The mismatch complaint, shown in red, or null.</summary>
    public string? PasswordProblem { get => _passwordProblem; private set => SetField(ref _passwordProblem, value); }

    /// <summary>True when "Change password" may be pressed.</summary>
    public bool CanChangePassword => OldPassword.Length > 0 && NewPassword.Length > 0 && ConfirmPassword.Length > 0 && !_status.IsBusy;

    /// <summary>Checks that the new password matches its confirmation, empties all three fields whatever happens, and asks the service to change the password. Returns whether the service accepted it.</summary>
    public async Task<bool> ChangePasswordAsync()
    {
        if (!CanChangePassword) return false;
        string old = OldPassword;
        string replacement = NewPassword;
        bool matches = NewPassword == ConfirmPassword;
        OldPassword = "";
        NewPassword = "";
        ConfirmPassword = "";
        if (!matches)
        {
            PasswordProblem = PasswordMismatchText;
            return false;
        }
        return await _status.ChangePasswordAsync(old, replacement);
    }

    // ---- Adult filter, version, updates ----

    /// <summary>True when the adult filter note shows: the service reports the filter as on.</summary>
    public bool ShowsAdultFilter => _status.Snapshot?.AdultFilterEnabled == true;

    /// <summary>The installed app's version line, "Version 1.0.42".</summary>
    public static string VersionLine => "Version " + BuildInfo.Version;

    /// <summary>The gray footer line naming the service's version, "SiteBlock service 1.0.42".</summary>
    public string ServiceVersionLine => $"SiteBlock service {_status.Snapshot?.Version}";

    /// <summary>True while a check runs, which shows a small spinner beside the button.</summary>
    public bool IsCheckingForUpdates => _status.Updater?.Phase.Kind == UpdatePhaseKind.Checking;

    /// <summary>True when "Check for updates" may be pressed (no check or install runs).</summary>
    public bool CanCheckForUpdates => _status.Updater is { IsWorking: false };

    /// <summary>The line under the button after a manual check, or null.</summary>
    public string? CheckResultText => _status.Updater?.CheckResult?.Text();

    /// <summary>True when that line is an error.</summary>
    public bool CheckResultIsError => _status.Updater?.CheckResult?.IsError() == true;

    /// <summary>"Check for updates": runs a manual check.</summary>
    public Task CheckForUpdatesAsync() => _status.Updater?.CheckNowAsync() ?? Task.CompletedTask;

    // ---- Uninstall ----

    /// <summary>The uninstall explanation: it needs the password and waits 48 hours, or the delay when that is longer, with every site still blocked.</summary>
    public string UninstallExplanation =>
        $"Uninstalling removes SiteBlock and every block. It needs your password and then waits {Formatting.Duration(CountdownMath.Clamp(Math.Max(Policy.Production.MinUninstallSeconds, CurrentDelay)))}, and every site stays blocked until then. You can cancel during the wait.";

    /// <summary>True while an uninstall is scheduled, which replaces the button with <see cref="UninstallScheduledText"/>.</summary>
    public bool UninstallScheduled => _status.Snapshot?.UninstallSecondsRemaining is not null;

    /// <summary>Whether the uninstall password form is open.</summary>
    public bool ConfirmingUninstall { get => _confirmingUninstall; private set => SetField(ref _confirmingUninstall, value); }

    /// <summary>The password typed for the uninstall form.</summary>
    public string UninstallPassword
    {
        get => _uninstallPassword;
        set
        {
            if (SetField(ref _uninstallPassword, value ?? "")) OnPropertyChanged(nameof(CanStartUninstall));
        }
    }

    /// <summary>Set to true when the uninstall password field should take the cursor; the view sets it back to false once it has.</summary>
    public bool FocusUninstallRequested { get => _focusUninstall; set => SetField(ref _focusUninstall, value); }

    /// <summary>True when "Start uninstall" may be pressed.</summary>
    public bool CanStartUninstall => UninstallPassword.Length > 0 && !_status.IsBusy;

    /// <summary>"Uninstall SiteBlock…": opens the password form.</summary>
    public void OpenUninstallForm()
    {
        ConfirmingUninstall = true;
        FocusUninstallRequested = true;
    }

    /// <summary>Cancel in the uninstall form: closes it and forgets the password.</summary>
    public void CancelUninstallForm()
    {
        UninstallPassword = "";
        ConfirmingUninstall = false;
    }

    /// <summary>"Start uninstall": sends the typed password, emptying the field first. The form closes when the service accepts and stays open (with the cursor back in the field) after a refusal.</summary>
    public async Task<bool> StartUninstallAsync()
    {
        if (!CanStartUninstall) return false;
        string typed = UninstallPassword;
        UninstallPassword = "";
        bool accepted = await _status.UninstallAsync(typed);
        if (accepted) ConfirmingUninstall = false;
        else FocusUninstallRequested = true;
        return accepted;
    }

    // ---- Leaving ----

    /// <summary>Called when the person leaves Settings: drops the update check's result line and forgets everything typed.</summary>
    public void Leave()
    {
        _status.Updater?.ClearCheckResult();
        Reset();
    }

    /// <summary>Forgets every pick, password and open form.</summary>
    public void Reset()
    {
        PickedDelay = null;
        DelayPassword = "";
        OldPassword = "";
        NewPassword = "";
        ConfirmPassword = "";
        PasswordProblem = null;
        CancelUninstallForm();
    }

    /// <summary>Stores one of the three password fields and raises what depends on it.</summary>
    private void SetPasswordField(ref string field, string? value, bool clearsProblem, [System.Runtime.CompilerServices.CallerMemberName] string? name = null)
    {
        if (!SetField(ref field, value ?? "", name)) return;
        if (clearsProblem) PasswordProblem = null;
        OnPropertyChanged(nameof(CanChangePassword));
    }

    /// <summary>Raises the properties computed from the picked delay.</summary>
    private void RaiseDelay()
    {
        OnPropertyChanged(nameof(ShownDelay));
        OnPropertyChanged(nameof(DelayHint));
        OnPropertyChanged(nameof(CanChangeDelay));
    }
}
