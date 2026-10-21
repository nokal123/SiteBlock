namespace SiteBlock.Core;

/// <summary>The rule that tells the watchdog when it may stop guarding the service. It lives in the library so unit tests can reach it.</summary>
public static class UninstallRule
{
    /// <summary>
    /// True only when the state file's bytes decode to a state that records a finished uninstall (<c>uninstalling</c> set and the uninstall countdown run out). That is the one case where the watchdog must not restart the service.
    /// Missing data (no file, no folder, unreadable), data that does not decode, and a bare <c>uninstalling</c> flag with no finished countdown (hand-editing) all return false, so none of them can switch the guard off.
    /// The bytes are decoded directly instead of through <see cref="StateStore.Load"/>, because loading would rename a damaged file out of the service's way.
    /// </summary>
    public static bool WatchdogShouldStandDown(byte[]? stateFileData)
    {
        if (stateFileData is null) return false;
        PersistedState? state = JsonCoding.TryDecode<PersistedState>(stateFileData);
        return state?.HasFinishedUninstall == true;
    }
}
