import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § UninstallRule: PersistedState.hasFinishedUninstall is "true only when
// uninstalling is true and pendingUninstall exists and is finished", and watchdogShouldStandDown(stateFileData:) "decodes the bytes of
// state.json and returns hasFinishedUninstall; returns false for missing or undecodable data, so damage to the state file keeps the
// watchdog guarding". The field names in the JSON below are typed from 01-overview-and-data.md § Data Model, not produced by the encoder.

// A state.json written by hand from the design's field names, with every field present. `pendingUninstall` is the JSON text for that field
// ("null" or a countdown object).
private func stateJSON(uninstalling: Bool, pendingUninstall: String) -> Data {
    let json = #"{"version":1,"passwordHash":null,"blocked":[],"delaySeconds":1800,"pendingDelayChange":null,"pendingUninstall":\#(pendingUninstall),"recovery":null,"failedAttempts":0,"lockout":null,"uninstalling":\#(uninstalling)}"#
    return Data(json.utf8)
}

private let noCountdown = "null"
private let runningCountdown = #"{"remainingSeconds":900,"totalSeconds":1800}"#
private let finishedCountdown = #"{"remainingSeconds":0,"totalSeconds":1800}"#

@Suite struct UninstallRuleTests {
    // MARK: data that is missing or damaged keeps the watchdog guarding

    @Test func noStateFileDataGivesFalse() {
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: nil) == false)
    }

    // Each of these either is not JSON at all or is JSON that does not decode to a state, so the watchdog must keep guarding.
    @Test(arguments: [
        ("empty data", Data()),
        ("garbage", Data("this is not json".utf8)),
        ("binary garbage", Data([0xFF, 0xFE, 0x00, 0x01, 0x80])),
        ("empty object", Data("{}".utf8)),
        ("version only", Data(#"{"version":1}"#.utf8)),
        ("array", Data("[]".utf8)),
        ("null", Data("null".utf8)),
        ("unclosed brace", Data("{".utf8)),
        ("whitespace", Data("  \n".utf8)),
        ("flag and countdown but no other required field", Data(#"{"uninstalling":true,"pendingUninstall":{"remainingSeconds":0,"totalSeconds":1800}}"#.utf8)),
        ("flag is a string", Data(#"{"version":1,"blocked":[],"delaySeconds":1800,"failedAttempts":0,"pendingUninstall":{"remainingSeconds":0,"totalSeconds":1800},"uninstalling":"true"}"#.utf8)),
        ("countdown is a number", Data(#"{"version":1,"blocked":[],"delaySeconds":1800,"failedAttempts":0,"pendingUninstall":0,"uninstalling":true}"#.utf8)),
        ("blocked is not a list", Data(#"{"version":1,"blocked":"x","delaySeconds":1800,"failedAttempts":0,"pendingUninstall":{"remainingSeconds":0,"totalSeconds":1800},"uninstalling":true}"#.utf8)),
    ])
    func dataThatDoesNotDecodeToAStateGivesFalse(label: String, data: Data) {
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: data) == false, "\(label)")
    }

    // A real state file cut short in the middle is damage, even though its first half has the flag and a finished countdown in it.
    @Test func aTruncatedStateFileGivesFalse() {
        let whole = stateJSON(uninstalling: true, pendingUninstall: finishedCountdown)
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: whole) == true, "premise: the whole file says the uninstall finished")
        for length in [1, 20, whole.count / 2, whole.count - 1] {
            #expect(UninstallRule.watchdogShouldStandDown(stateFileData: whole.prefix(length)) == false, "the first \(length) bytes")
        }
    }

    // MARK: the flag and the countdown

    // The flag alone is what a hand edit would set: nothing says an uninstall ran, so the watchdog keeps guarding.
    @Test func theFlagWithNoUninstallCountdownGivesFalse() {
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: stateJSON(uninstalling: true, pendingUninstall: noCountdown)) == false)
    }

    @Test func theFlagWithARunningCountdownGivesFalse() {
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: stateJSON(uninstalling: true, pendingUninstall: runningCountdown)) == false)
    }

    // A countdown with a thousandth of a second left has not finished.
    @Test(arguments: ["0.001", "0.5", "1", "1800"])
    func theFlagWithACountdownThatStillHasTimeLeftGivesFalse(remaining: String) {
        let countdown = #"{"remainingSeconds":\#(remaining),"totalSeconds":1800}"#
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: stateJSON(uninstalling: true, pendingUninstall: countdown)) == false)
    }

    @Test func theFlagWithAFinishedCountdownGivesTrue() {
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: stateJSON(uninstalling: true, pendingUninstall: finishedCountdown)) == true)
    }

    // A finished countdown with the flag unset: the uninstall has not been marked as started, so the watchdog keeps guarding.
    @Test func aFinishedCountdownWithoutTheFlagGivesFalse() {
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: stateJSON(uninstalling: false, pendingUninstall: finishedCountdown)) == false)
    }

    @Test func neitherTheFlagNorACountdownGivesFalse() {
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: stateJSON(uninstalling: false, pendingUninstall: noCountdown)) == false)
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: stateJSON(uninstalling: false, pendingUninstall: runningCountdown)) == false)
    }

    // Nothing else in the file changes the answer: a state full of other pending work, with the flag and a finished uninstall, still stands down.
    @Test func otherFieldsInTheStateDoNotChangeTheAnswer() throws {
        var state = PersistedState(passwordHash: PasswordHash(algorithm: "pbkdf2-sha256", iterations: 210_000, salt: "c2FsdA==", hash: "aGFzaA=="), blocked: [BlockedSite(domain: "reddit.com", hosts: ["reddit.com"], pendingUnblock: Countdown(seconds: 100))], delaySeconds: 1800, pendingDelayChange: PendingDelayChange(newDelaySeconds: 60, countdown: Countdown(seconds: 50)), pendingUninstall: Countdown(remainingSeconds: 0, totalSeconds: 1800), recovery: Countdown(seconds: 99), failedAttempts: 3, lockout: Countdown(seconds: 77), uninstalling: true)
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: try JSONCoding.encoder.encode(state)) == true)
        state.uninstalling = false
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: try JSONCoding.encoder.encode(state)) == false)
        state.uninstalling = true
        state.pendingUninstall = Countdown(seconds: 1)
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: try JSONCoding.encoder.encode(state)) == false)
        state.pendingUninstall = nil
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: try JSONCoding.encoder.encode(state)) == false)
    }

    // MARK: the whole path, from the engine through the state file to the watchdog

    // A real uninstall: the engine runs the countdown, the state store writes the file, and the watchdog reads the bytes back from disk. The
    // watchdog must keep guarding while the countdown runs (flag not yet set) and stand down only once it has finished.
    // Design change: an uninstall waits max(policy.minUninstallSeconds, delaySeconds) (01-overview-and-data.md § Commands, § Fixed Policy
    // Values). The test needs a countdown it can run out with 1800 s of ticks, so the engine uses shortUninstallPolicy, where the uninstall
    // waits the 1800 s delay; with designPolicy it would wait 172800 s and the watchdog would never see a finished uninstall here.
    @Test func theWatchdogStandsDownOnlyAfterARealUninstallCountdownHasFinishedAndBeenSaved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("siteblock-uninstallrule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let store = StateStore(url: url)
        let engine = makeEngine(policy: shortUninstallPolicy)
        func watchdogView() throws -> Bool {
            try store.save(engine.state)
            return UninstallRule.watchdogShouldStandDown(stateFileData: try Data(contentsOf: url))
        }
        #expect(try watchdogView() == false, "nothing has been requested")
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(try watchdogView() == false, "the countdown has just started")
        _ = engine.tick(elapsed: 1799)
        #expect(try watchdogView() == false, "one second is left")
        expectSuccess(engine.send(.cancelUninstall))
        #expect(try watchdogView() == false, "a cancelled uninstall never stands the watchdog down")
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.tick(elapsed: 1800) == true)
        #expect(try watchdogView() == true, "the countdown finished and the flag is set")
        // A file that has gone missing afterwards is data that is missing: the watchdog guards again.
        try FileManager.default.removeItem(at: url)
        #expect(UninstallRule.watchdogShouldStandDown(stateFileData: try? Data(contentsOf: url)) == false)
    }
}

// 02-core-components.md § UninstallRule: "PersistedState.hasFinishedUninstall: Bool — true only when uninstalling is true and
// pendingUninstall exists and is finished."
@Suite struct HasFinishedUninstallTests {
    // A state with the given flag and uninstall countdown and nothing else set.
    private func state(uninstalling: Bool, pendingUninstall: Countdown?) -> PersistedState {
        PersistedState(delaySeconds: 1800, pendingUninstall: pendingUninstall, uninstalling: uninstalling)
    }

    @Test(arguments: [
        (true, Countdown(remainingSeconds: 0, totalSeconds: 1800), true),
        (true, Countdown(remainingSeconds: 900, totalSeconds: 1800), false),
        (true, Countdown(remainingSeconds: 0.001, totalSeconds: 1800), false),
        (true, Countdown(seconds: 1800), false),
        (false, Countdown(remainingSeconds: 0, totalSeconds: 1800), false),
        (false, Countdown(remainingSeconds: 900, totalSeconds: 1800), false),
    ])
    func isTrueOnlyForTheFlagTogetherWithAFinishedCountdown(uninstalling: Bool, countdown: Countdown, expected: Bool) {
        #expect(state(uninstalling: uninstalling, pendingUninstall: countdown).hasFinishedUninstall == expected)
    }

    @Test func isFalseWhenThereIsNoUninstallCountdownWhateverTheFlagIs() {
        #expect(state(uninstalling: true, pendingUninstall: nil).hasFinishedUninstall == false)
        #expect(state(uninstalling: false, pendingUninstall: nil).hasFinishedUninstall == false)
        #expect(PersistedState.fresh().hasFinishedUninstall == false)
    }

    // The other countdowns in the state are not the uninstall countdown: a finished recovery or lockout does not make an uninstall finished.
    @Test func aFinishedCountdownThatIsNotTheUninstallCountdownDoesNotCount() {
        var other = PersistedState(delaySeconds: 1800, recovery: Countdown(remainingSeconds: 0, totalSeconds: 100), lockout: Countdown(remainingSeconds: 0, totalSeconds: 100), uninstalling: true)
        other.blocked = [BlockedSite(domain: "reddit.com", hosts: ["reddit.com"], pendingUnblock: Countdown(remainingSeconds: 0, totalSeconds: 100))]
        other.pendingDelayChange = PendingDelayChange(newDelaySeconds: 60, countdown: Countdown(remainingSeconds: 0, totalSeconds: 100))
        #expect(other.hasFinishedUninstall == false)
    }

    // Driven through the engine: the property follows the real lifecycle of an uninstall. Design change: shortUninstallPolicy keeps the
    // countdown at the 1800 s delay (see theWatchdogStandsDownOnlyAfterARealUninstallCountdownHasFinishedAndBeenSaved).
    @Test func followsTheEnginesUninstallFromRequestThroughCancelAndFinish() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        #expect(engine.state.hasFinishedUninstall == false)
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.hasFinishedUninstall == false, "requested, not finished")
        _ = engine.tick(elapsed: 1799.5)
        #expect(engine.state.hasFinishedUninstall == false, "half a second left")
        expectSuccess(engine.send(.cancelUninstall))
        #expect(engine.state.hasFinishedUninstall == false, "cancelled")
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.tick(elapsed: 1800) == true)
        #expect(engine.state.uninstalling == true)
        #expect(engine.state.hasFinishedUninstall == true, "finished and flagged")
    }
}
