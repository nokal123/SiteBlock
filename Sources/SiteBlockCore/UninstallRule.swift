import Foundation

/// The rule that tells the watchdog when it may stop guarding the daemon. It lives in the library so unit tests can reach it.
public enum UninstallRule {
    /// True only when the state file's bytes decode to a state that records a finished uninstall (`uninstalling` set and the uninstall countdown run out). That is the one case where the watchdog must not reload the daemon. Missing data (no file, no folder, unreadable), data that does not decode, and a bare `uninstalling` flag with no finished countdown (hand-editing) all return false, so none of them can switch the guard off. The bytes are decoded directly instead of through `StateStore.load`, because loading would rename a damaged file out of the daemon's way.
    public static func watchdogShouldStandDown(stateFileData: Data?) -> Bool {
        guard let data = stateFileData, let state = try? JSONCoding.decoder.decode(PersistedState.self, from: data) else { return false }
        return state.hasFinishedUninstall
    }
}
