namespace SiteBlock.AppLogic;

/// <summary>Whether the app can reach the SiteBlock service right now.</summary>
public enum ConnectionState
{
    /// <summary>No answer has come back yet since the app started.</summary>
    Connecting,
    /// <summary>The last status request was answered.</summary>
    Connected,
    /// <summary>The last status request failed; <see cref="DaemonConnection.Message"/> is the sentence to show.</summary>
    NotRunning,
}

/// <summary>The connection state plus, when the service could not be reached, the sentence that says why.</summary>
/// <param name="State">Where the connection stands.</param>
/// <param name="Message">The sentence to show for <see cref="ConnectionState.NotRunning"/>, such as "The SiteBlock service isn't running."; null otherwise.</param>
public sealed record DaemonConnection(ConnectionState State, string? Message = null)
{
    /// <summary>The state before any answer.</summary>
    public static DaemonConnection Connecting { get; } = new(ConnectionState.Connecting);

    /// <summary>The state after an answer.</summary>
    public static DaemonConnection Connected { get; } = new(ConnectionState.Connected);

    /// <summary>The state after a failed status request, with its sentence.</summary>
    public static DaemonConnection NotRunning(string message) => new(ConnectionState.NotRunning, message);
}

/// <summary>Which part of the panel a message belongs to, so each message appears next to the control that caused it.</summary>
public enum FeedbackArea
{
    /// <summary>The "add a site" field.</summary>
    Add,
    /// <summary>One blocked-site row, named by <see cref="FeedbackScope.Name"/> (its domain).</summary>
    Site,
    /// <summary>One blocked-part-of-a-site row, named by its rule text such as youtube.com/shorts.</summary>
    Rule,
    /// <summary>The banners at the top of the panel.</summary>
    Banner,
    /// <summary>The delay form in Settings.</summary>
    Delay,
    /// <summary>The change-password form in Settings.</summary>
    Password,
    /// <summary>The uninstall form in Settings.</summary>
    Uninstall,
    /// <summary>The "Choose a SiteBlock password" form (at the first block, or in the "Choose a new password" banner).</summary>
    Setup,
}

/// <summary>A place on the panel where a message shows. Rows carry the name of their site or rule; every other place has no name.</summary>
/// <param name="Area">The part of the panel.</param>
/// <param name="Name">The domain or rule text for <see cref="FeedbackArea.Site"/> and <see cref="FeedbackArea.Rule"/>; null otherwise.</param>
public sealed record FeedbackScope(FeedbackArea Area, string? Name = null)
{
    /// <summary>The add field.</summary>
    public static FeedbackScope Add { get; } = new(FeedbackArea.Add);
    /// <summary>The banners.</summary>
    public static FeedbackScope Banner { get; } = new(FeedbackArea.Banner);
    /// <summary>The delay form.</summary>
    public static FeedbackScope Delay { get; } = new(FeedbackArea.Delay);
    /// <summary>The change-password form.</summary>
    public static FeedbackScope Password { get; } = new(FeedbackArea.Password);
    /// <summary>The uninstall form.</summary>
    public static FeedbackScope Uninstall { get; } = new(FeedbackArea.Uninstall);
    /// <summary>The choose-a-password form.</summary>
    public static FeedbackScope Setup { get; } = new(FeedbackArea.Setup);

    /// <summary>The row of one blocked site.</summary>
    public static FeedbackScope Site(string domain) => new(FeedbackArea.Site, domain);

    /// <summary>The row of one blocked part of a site.</summary>
    public static FeedbackScope Rule(string rule) => new(FeedbackArea.Rule, rule);
}

/// <summary>One message shown on the panel: the service's error sentence or its confirmation sentence.</summary>
/// <param name="Id">A number that is different for every message, so a timer started for an old message cannot clear a newer one.</param>
/// <param name="Scope">Where the message shows.</param>
/// <param name="Text">The sentence.</param>
/// <param name="IsError">True for an error (shown in red), false for a confirmation.</param>
public sealed record Feedback(int Id, FeedbackScope Scope, string Text, bool IsError);

/// <summary>How the first block went, when the first password and the first site are sent one after the other.</summary>
public enum FirstBlockOutcome
{
    /// <summary>The password was not set, so nothing else was sent. The reason shows inside the password form.</summary>
    PasswordNotSet,
    /// <summary>The password was set, but the service refused the site. The reason shows under the add field.</summary>
    PasswordSetSiteRefused,
    /// <summary>The password was set and the site is blocked.</summary>
    Blocked,
}

/// <summary>What the "For a while" form collected, ready to send.</summary>
/// <param name="WindowSeconds">How long the site stays open.</param>
/// <param name="StartSeconds">How long to wait before it opens.</param>
/// <param name="Password">The SiteBlock password.</param>
public sealed record TemporaryUnblockChoice(int WindowSeconds, int StartSeconds, string Password);

/// <summary>The arithmetic behind countdowns that keep ticking between status polls.</summary>
public static class CountdownMath
{
    /// <summary>
    /// The seconds left on a countdown the service reported as <paramref name="reported"/> seconds when its reply arrived at <paramref name="asOfMilliseconds"/>, as of <paramref name="nowMilliseconds"/> (both on the monotonic clock).
    /// It rounds up, because the service rounds up too, so a running countdown never shows 0 early. It never goes below 0 and never above <paramref name="reported"/>.
    /// </summary>
    public static int Remaining(long reported, long asOfMilliseconds, long nowMilliseconds)
    {
        // A clock reading from before the reply (which only a test can produce) counts as no time passed.
        long elapsedMs = Math.Max(0, nowMilliseconds - asOfMilliseconds);
        // The report is capped far above any real countdown, so multiplying by 1000 can never overflow.
        long leftMs = Math.Clamp(reported, 0, 1_000_000_000_000) * 1000 - elapsedMs;
        if (leftMs <= 0) return 0;
        long seconds = (leftMs + 999) / 1000;
        return (int)Math.Min(int.MaxValue, seconds);
    }

    /// <summary>A reported number of seconds as an int for the text helpers, clamped to 0 and <see cref="int.MaxValue"/>.</summary>
    public static int Clamp(long seconds) => (int)Math.Clamp(seconds, 0, int.MaxValue);
}
