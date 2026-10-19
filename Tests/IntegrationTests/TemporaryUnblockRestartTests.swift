import Foundation
import SiteBlockCore
import Testing

// A real siteblockd that is stopped in the middle of a temporary unblock and started again. Design: 05-testing-and-operations.md § Integration Tests ("Restarting the daemon in the
// middle of a start wait, and again in the middle of a window, keeps the remaining times: the countdown continues from the last save and neither restarts nor finishes early"),
// 01-overview-and-data.md § Fixed Policy Values ("State is saved to disk after every command ... A temporary unblock counts as a running countdown"), 03-daemon-cli-app.md § Daemon Runtime
// ("so a restart in the middle continues from the last save"; SIGTERM saves state) and § Data Model (a countdown stores the time left, never a finish time).
//
// The bounds come from stopwatches started before the approving request, so they hold on a slow machine too: a countdown that restarted from its full length is above the upper bound, one that
// finished early is below the lower bound. The daemon's own clock only runs while the daemon runs, so the downtime does not count.

private let password = SandboxDaemon.password

// A command that changes the saved state without touching the block lists: one wrong password, which the engine counts (failedAttempts goes up). The runtime saves the state after a command that
// changed it (the catch-up before the command has already moved every countdown forward), so this is how a test makes the daemon write the current remaining times to disk before it is killed.
private func makeTheDaemonSave(_ daemon: SandboxDaemon) throws {
    let reply = try daemon.send(.unblock, domain: "example.com", password: "wrong-password-1")
    try require(reply.errorCode == .wrongPassword, "the forcing command should have been refused as a wrong password: \(reply.errorCode?.rawValue ?? "?")")
}

@Suite("Temporary unblock and restarts")
struct TemporaryUnblockRestartTests {
    // 05: "Restarting the daemon in the middle of a start wait ... keeps the remaining times". A start wait of 8 s is interrupted 3 s in, after a command has made the daemon save (SIGKILL gives
    // the daemon no other chance to write it). After the restart the site is still blocked, it opens after the rest of the wait and not before, and the status
    // shows about 5 s, not 8 and not 0.
    @Test(arguments: StopMethod.allCases)
    func restartingInTheMiddleOfAStartWaitContinuesFromTheLastSave(method: StopMethod) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            try daemon.requireTwoSecondDelay()
            let blocked = daemon.hostsExpected(blocking: ["reddit.com", "example.com"])
            let open = daemon.hostsExpected(blocking: ["example.com"])
            let watch = Stopwatch()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 20, startSeconds: 8).requireOK()
            let approvedAt = watch.elapsed
            pause(3.0 - watch.elapsed)
            let before = watch.elapsed
            try makeTheDaemonSave(daemon)
            daemon.stop(method)
            let stoppedAt = watch.elapsed
            let restart = Stopwatch()
            try daemon.start()
            let status = try daemon.temporaryStatus(ofSite: "reddit.com")
            let restartSpan = restart.elapsed
            let waiting = try #require(status, "the temporary unblock was lost in the restart")
            let opensIn = try #require(waiting.opensInSeconds, "it must still be waiting")
            let lowest = Int((8 - stoppedAt - restartSpan).rounded(.up))
            let highest = Int((8 - (before - approvedAt)).rounded(.up))
            #expect(waiting.isOpen == false && waiting.windowSeconds == 20 && waiting.secondsRemaining == 20)
            #expect(opensIn >= max(lowest, 1) && opensIn <= highest, "opens in \(opensIn) s after the restart; expected between \(max(lowest, 1)) and \(highest) (8 s wait, stopped \(before)-\(stoppedAt) s in)")
            #expect(opensIn < 8, "the start wait must not start over")
            #expect(daemon.hostsText() == blocked, "still blocked right after the restart")

            let opened = waitUntil(timeout: 9.0) { daemon.hostsText() == open }
            let openedAfter = restart.elapsed
            #expect(opened != nil, "the site never opened after the restart; file:\n\(daemon.hostsText())")
            #expect(openedAfter >= 8 - stoppedAt, "the site opened \(openedAfter) s after the restart, before the rest of the wait (at least \(8 - stoppedAt) s) was over")
            #expect(openedAfter <= Double(highest) + 3.0, "the site opened \(openedAfter) s after the restart; the wait seems to have started over")
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com")?.isOpen == true)
        }
    }

    // 05: "... and again in the middle of a window". A window of 8 s is interrupted about 3 s after the site opened. After the restart the site is still open (its lines are not written back by
    // the first pass), the window has about 5 s left, and the lines return after that and not before.
    @Test(arguments: StopMethod.allCases)
    func restartingInTheMiddleOfAWindowKeepsTheSiteOpenAndContinuesTheWindow(method: StopMethod) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            try daemon.requireTwoSecondDelay()
            let blocked = daemon.hostsExpected(blocking: ["reddit.com", "example.com"])
            let open = daemon.hostsExpected(blocking: ["example.com"])
            let openLists = designLists(sites: ["example.com"])
            let watch = Stopwatch()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 8, startSeconds: 2).requireOK()
            try require(waitUntil(timeout: 4.0) { daemon.hostsText() == open } != nil, "the site never opened:\n\(daemon.hostsText())")
            let openSeen = watch.elapsed
            pause(openSeen + 3.0 - watch.elapsed)
            let before = watch.elapsed
            try makeTheDaemonSave(daemon)
            daemon.stop(method)
            let stoppedAt = watch.elapsed
            let restart = Stopwatch()
            try daemon.start()
            let status = try daemon.temporaryStatus(ofSite: "reddit.com")
            let restartSpan = restart.elapsed
            let current = try #require(status, "the open temporary unblock was lost in the restart")
            let lowest = Int((8 - (stoppedAt - 2.0) - restartSpan).rounded(.up))
            let highest = Int((8 - (before - openSeen)).rounded(.up))
            #expect(current.isOpen == true && current.opensInSeconds == nil && current.windowSeconds == 8)
            #expect(current.secondsRemaining >= max(lowest, 1) && current.secondsRemaining <= highest, "\(current.secondsRemaining) s of the window left; expected between \(max(lowest, 1)) and \(highest)")
            #expect(current.secondsRemaining < 8, "the window must not start over")
            #expect(daemon.hostsText() == open, "the restart must not write the open site's lines back; file:\n\(daemon.hostsText())")
            #expect(waitUntil(timeout: 1.5) { daemon.browserFilesHold(openLists) } != nil, "nor its entries")
            pause(0.5)
            #expect(daemon.hostsText() == open)

            let ended = waitUntil(timeout: 9.0) { daemon.hostsText() == blocked }
            let endedAfter = restart.elapsed
            #expect(ended != nil, "the site stayed open after the window should have ended; file:\n\(daemon.hostsText())")
            #expect(endedAfter >= 8 - (stoppedAt - 2.0), "the site was blocked again \(endedAfter) s after the restart, before the rest of the window (at least \(8 - (stoppedAt - 2.0)) s) was over")
            #expect(endedAfter <= Double(highest) + 3.0, "blocked again only \(endedAfter) s after the restart; the window seems to have started over")
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com") == nil)
        }
    }

    // 01 § Fixed Policy Values and 03 § Daemon Runtime: the state is saved after every command that CHANGES it, and at least every 15 seconds while a countdown runs, "so a crash loses at most 15 seconds of countdown
    // progress"; a command that changes nothing (`status`, a refused request) does not write the file. An earlier version of this test expected the progress to be saved by such a command; the design was corrected,
    // because the 15-second timer save already bounds the loss and a write per status poll buys nothing. So the bound is checked end to end: a start wait of 60 s, 19 s of it gone, then commands that change nothing,
    // then SIGKILL. The restarted daemon must hold at least the true remaining time (it never loses time it did not save) and at most 15 s more than it (the timer save at about 15 s must have happened; without it the
    // restarted daemon would hold the full 60 s, about 19 s more than the true remaining time). The 15-second save tests in TemporaryUnblockTests prove the file is written; this proves what a crash then costs.
    @Test func aCrashAfterCommandsThatChangeNothingLosesAtMostFifteenSecondsOfProgress() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let watch = Stopwatch()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 600, startSeconds: 60).requireOK()
            let approvedAt = watch.elapsed
            pause(18.5 - watch.elapsed)
            // Commands that change nothing: a read-only one and three refusals.
            _ = try daemon.status()
            try daemon.send(.cancelDelayChange).requireNotOK(.nothingPending)
            try daemon.send(.cancelUninstall).requireNotOK(.nothingPending)
            try daemon.send(.unblock, domain: "nowhere.example", password: password).requireNotOK(.notBlocked)
            let before = watch.elapsed
            daemon.stop(.sigkill)
            let stoppedAt = watch.elapsed
            let restart = Stopwatch()
            try daemon.start()
            let opensIn = try #require(try daemon.temporaryStatus(ofSite: "reddit.com")?.opensInSeconds, "the temporary unblock was lost in the restart")
            let restartSpan = restart.elapsed
            // The true time left when the daemon died is between 60 - stoppedAt and 60 - (before - approvedAt); the restarted daemon's own clock has run for at most `restartSpan` since.
            let lowest = Int((60 - stoppedAt - restartSpan).rounded(.up))
            let highest = Int((60 - (before - approvedAt) + 15).rounded(.up))
            #expect(opensIn >= lowest, "restarted with \(opensIn) s left, less than the true remaining time (at least \(lowest) s)")
            #expect(opensIn <= highest, "restarted with \(opensIn) s left; a crash may lose at most 15 s of progress, so at most \(highest) s was expected")
            #expect(opensIn < 60, "the start wait must not start over")
        }
    }

    // 03 § Daemon Runtime: "A command that changes nothing (for example `status`, or a refused request) does not write the file." The daemon ticks only every 60 s, so no timer save can come in between; the state
    // file keeps its identity (same file, same modification time) and bytes through a status request and three refusals while a temporary unblock waits, and a command that does change the state (a wrong password,
    // which counts a failed attempt) writes it.
    @Test func aCommandThatChangesNothingDoesNotWriteTheStateFile() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 600, startSeconds: 600).requireOK()
            let bytes = try #require(FileManager.default.contents(atPath: daemon.statePath))
            let identityBefore = identity(of: daemon.statePath)
            try require(identityBefore != nil, "the state file should exist")
            pause(1.1)
            _ = try daemon.status()
            try daemon.send(.cancelDelayChange).requireNotOK(.nothingPending)
            try daemon.send(.cancelUninstall).requireNotOK(.nothingPending)
            try daemon.send(.unblock, domain: "nowhere.example", password: password).requireNotOK(.notBlocked)
            #expect(identity(of: daemon.statePath) == identityBefore, "a command that changes nothing wrote the state file")
            #expect(FileManager.default.contents(atPath: daemon.statePath) == bytes)
            // Positive control: a wrong password changes the state (failedAttempts), so it IS written, and the countdown progress made so far goes to disk with it.
            #expect(try daemon.send(.unblock, domain: "reddit.com", password: "not-the-password").errorCode == .alreadyPending)
            #expect(try daemon.send(.temporaryUnblock, domain: "reddit.com", password: "not-the-password", seconds: 300).errorCode == .alreadyPending)
            let other = try daemon.send(.setDelay, password: "not-the-password", seconds: 600)
            #expect(other.errorCode == .wrongPassword)
            #expect(identity(of: daemon.statePath) != identityBefore, "a command that changes the state must write the file")
            #expect(daemon.stateObject()?["failedAttempts"] as? Int == 1)
        }
    }

    // 03 § Daemon Runtime, Signals: "`SIGTERM` ... saves state and exits with code 0". The two-leg tests above force a save with a command right before they stop the daemon, so their SIGTERM leg proves no more than their
    // SIGKILL leg. Here nothing is sent after the approval: a start wait of 40 s is 6 s old when SIGTERM arrives, well before the 15-second timer save, so only the SIGTERM handler can have written the progress. The restarted
    // daemon must hold about 34 s (a two-sided bound from the stopwatch, with one 0.2 s tick of slack for the last tick before the signal), not the 40 s of the approval-time save.
    @Test func aSigtermSavesTheCountdownProgressWithoutAnyCommand() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let watch = Stopwatch()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 600, startSeconds: 40).requireOK()
            let approvedAt = watch.elapsed
            pause(6.0 - watch.elapsed)
            let before = watch.elapsed
            let exit = daemon.terminate()
            let stoppedAt = watch.elapsed
            #expect(exit?.status == 0 && exit?.killedBySignal == false, "SIGTERM should end the daemon with exit code 0; got \(String(describing: exit))")
            let restart = Stopwatch()
            try daemon.start()
            let waiting = try #require(try daemon.temporaryStatus(ofSite: "reddit.com"), "the temporary unblock was lost in the restart")
            let restartSpan = restart.elapsed
            let opensIn = try #require(waiting.opensInSeconds)
            let lowest = Int((40 - stoppedAt - restartSpan).rounded(.up))
            let highest = Int((40 - (before - approvedAt) + 0.5).rounded(.up))
            #expect(opensIn >= lowest && opensIn <= highest, "restarted with \(opensIn) s left; about 34 was expected, between \(lowest) and \(highest)")
            #expect(opensIn < 40 && waiting.isOpen == false && waiting.windowSeconds == 600)
        }
    }

    // 03 § Daemon Runtime: "The state is saved in that same tick, because `engine.tick` returned `true`", and the catch-up before a command "save[s] and enforce[s] as a tick would". The daemon here ticks every
    // 60 s, so only the catch-up before a command can find the opening or the ending. A refused command follows it and changes nothing itself, and the daemon is killed right after: the restarted daemon
    // must already know that the site opened (or that it finished), because the catch-up saved that at once.
    @Test(arguments: ["opening", "ending"])
    func anOpeningOrEndingFoundByTheCatchUpIsSavedAtOnce(phase: String) throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            try daemon.requireTwoSecondDelay()
            let opening = phase == "opening"
            let watch = Stopwatch()
            try daemon.sendTemporary(domain: "reddit.com", seconds: opening ? 3600 : 1, startSeconds: 2).requireOK()
            pause((opening ? 2.6 : 3.6) - watch.elapsed)
            try daemon.send(.add, domain: "example.com").requireNotOK(.alreadyBlocked)
            daemon.stop(.sigkill)
            try daemon.start()
            let restored = try daemon.temporaryStatus(ofSite: "reddit.com")
            if opening {
                #expect(restored?.isOpen == true, "the opening found by the catch-up was not saved; after the restart the status is \(String(describing: restored))")
                #expect(daemon.hostsText() == daemon.hostsExpected(blocking: ["example.com"]), "and the restarted daemon must keep the site open; file:\n\(daemon.hostsText())")
            } else {
                #expect(restored == nil, "the ending found by the catch-up was not saved; after the restart the status is \(String(describing: restored))")
                #expect(daemon.hostsText() == daemon.hostsExpected(blocking: ["reddit.com", "example.com"]))
            }
        }
    }

    // The approval itself is saved: a SIGKILL right after the reply loses nothing (no later command is needed).
    @Test func aTemporaryUnblockSurvivesAKillRightAfterTheApprovalReply() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let watch = Stopwatch()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 600, startSeconds: 30).requireOK()
            daemon.stop(.sigkill)
            try daemon.start()
            let restored = try #require(try daemon.temporaryStatus(ofSite: "reddit.com"), "the approved temporary unblock was not saved")
            #expect(restored.isOpen == false && restored.secondsRemaining == 600 && restored.windowSeconds == 600)
            #expect((Int((30 - watch.elapsed).rounded(.up))...30).contains(restored.opensInSeconds ?? -1), "got \(String(describing: restored.opensInSeconds)) after \(watch.elapsed) s")
            #expect(daemon.hostsText() == daemon.hostsExpected(blocking: ["reddit.com"]))
        }
    }

    // The same for a path rule, killed in the middle of its start wait: it comes back waiting with about the saved time, and the browser files still hold its entry next to the site.
    @Test func aPathRulesStartWaitContinuesAfterAKill() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.requireTwoSecondDelay()
            let watch = Stopwatch()
            try daemon.sendTemporary(.temporaryUnblockPath, domain: "youtube.com/shorts", seconds: 600, startSeconds: 20).requireOK()
            let approvedAt = watch.elapsed
            pause(2.5 - watch.elapsed)
            let before = watch.elapsed
            try daemon.send(.add, domain: "example.com").requireOK()
            daemon.stop(.sigkill)
            let stoppedAt = watch.elapsed
            let restart = Stopwatch()
            try daemon.start()
            let restored = try #require(try daemon.temporaryStatus(ofRule: "youtube.com/shorts"), "the rule's temporary unblock was lost in the restart")
            let restartSpan = restart.elapsed
            let opensIn = try #require(restored.opensInSeconds)
            let lowest = Int((20 - stoppedAt - restartSpan).rounded(.up))
            let highest = Int((20 - (before - approvedAt)).rounded(.up))
            #expect(restored.isOpen == false && restored.windowSeconds == 600 && restored.secondsRemaining == 600)
            #expect(opensIn >= lowest && opensIn <= highest && opensIn < 20, "opens in \(opensIn) s; expected between \(lowest) and \(highest)")
            #expect(waitUntil(timeout: 1.5) { daemon.browserFilesHold(designLists(sites: ["example.com"], rules: [(domain: "youtube.com", path: "/shorts")])) } != nil, "the waiting rule is still in the browser lists")
        }
    }
}
