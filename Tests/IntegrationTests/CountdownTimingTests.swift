import Foundation
import SiteBlockCore
import Testing

// How long countdowns really take in the real siteblockd: never shorter than they should be, whatever point of the tick cycle a command lands on, however many commands arrive during the wait, and however long the daemon itself was frozen.
// Design: 01-overview-and-data.md § Data Model (Countdown, measured with a clock that ignores the wall clock), § Fixed Policy Values; 03-daemon-cli-app.md § DaemonRuntime ("Tick" step 1 measures elapsed time; "Before every command" brings every countdown up to date and records now as the last tick time); 02-core-components.md § Engine ("Tick rule").
// Every measurement starts its stopwatch BEFORE the request that creates the countdown is sent. The daemon starts counting only after it has read the request, so a correct daemon can never be seen finishing earlier than the full delay on that stopwatch; "later" is bounded loosely, because only "never early" is a hard rule.
@Suite("Countdown timing")
struct CountdownTimingTests {
    static let password = SandboxDaemon.password

    // MARK: A slow tick

    // The design says a countdown never finishes early. With a 1 s tick the daemon notices a finished countdown up to a second late, so the bug this guards against (a countdown charged for time before it started, or for a tick that had not happened yet) shows most clearly here. Ten unblocks start at ten points spread over one whole tick period (one random point inside each tenth of it), whatever the daemon's own tick phase is. Each site must leave the hosts file at least 2.0 s after its own request was sent.
    @Test func tenUnblocksAtDifferentPointsOfAOneSecondTickAllTakeAtLeastTheFullDelay() throws {
        try withDaemon(tick: 1.0) { daemon in
            try daemon.setUp()
            try daemon.requireTwoSecondDelay()
            let domains = (0..<10).map { "phase\($0).example.org" }
            for domain in domains { try daemon.block(domain) }
            let offsets = (0..<10).map { (Double($0) + Double.random(in: 0..<1)) / 10.0 }
            let clock = Stopwatch()
            var sentAt = [Double?](repeating: nil, count: 10)
            var goneAt = [Double?](repeating: nil, count: 10)
            var next = 0
            while clock.elapsed < 9.0 {
                if next < 10, clock.elapsed >= offsets[next] {
                    sentAt[next] = clock.elapsed
                    try daemon.send(.unblock, domain: domains[next], password: Self.password).requireOK()
                    next += 1
                    continue
                }
                // Read the file first and take the time after it, so a recorded time is never earlier than the removal it reports.
                let view = daemon.hosts()
                let now = clock.elapsed
                for index in 0..<next where goneAt[index] == nil && !view.blocks(domains[index]) { goneAt[index] = now }
                if next == 10, goneAt.allSatisfy({ $0 != nil }) { break }
                pause(0.01)
            }
            var summary: [String] = []
            for index in 0..<10 {
                guard let sent = sentAt[index], let gone = goneAt[index] else {
                    Issue.record("\(domains[index]) was not unblocked within 9 s (sent: \(String(describing: sentAt[index])))")
                    continue
                }
                let took = gone - sent
                summary.append(String(format: "%.2f", took))
                #expect(took >= 2.0, "\(domains[index]) left the hosts file \(took) s after its unblock request, before the 2 s delay was over. Start offsets \(offsets), all times \(summary)")
                #expect(took < 5.0, "\(domains[index]) took \(took) s")
            }
            let status = try daemon.status()
            #expect(status.blocked.isEmpty)
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
        }
    }

    // MARK: Other countdowns

    // 01 § Commands (setDelay): a shorter delay waits out the CURRENT delay. With a delay of 2 s, asking for 1 s changes nothing until 2 s have passed: at 1.0 s the delay is still 2 and a change is pending, and it becomes 1 no earlier than 2.0 s after the request (and soon after).
    @Test func aShorterDelayStaysPendingForTheFullCurrentDelayThenApplies() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let phase = daemon.pauseToRandomTickPhase()
            let watch = Stopwatch()
            let reply = try daemon.send(.setDelay, password: Self.password, seconds: 1).requireOK()
            #expect(reply.status?.delaySeconds == 2, "a shorter delay must not apply at once")
            pause(1.0 - watch.elapsed)
            let midway = try daemon.status()
            #expect(midway.delaySeconds == 2, "the delay was already \(midway.delaySeconds) s at about 1 s of the 2 s wait (request \(phase) s into a tick)")
            #expect(midway.pendingDelay?.newDelaySeconds == 1)
            let applied = waitUntil(timeout: 3.0, interval: 0.02) { (try? daemon.status().delaySeconds) == 1 }
            let appliedAt = watch.elapsed
            #expect(applied != nil, "the 1 s delay was never applied")
            #expect(appliedAt >= 2.0, "the delay changed \(appliedAt) s after the request, before the current 2 s delay was waited out (request \(phase) s into a tick)")
            #expect(appliedAt <= 2.8, "the delay changed only after \(appliedAt) s; the 0.2 s tick should apply it at about 2.2 to 2.3 s")
            let after = try daemon.status()
            #expect(after.pendingDelay == nil)
            #expect(after.delaySeconds == 1)
        }
    }

    // 01 § Fixed Policy Values: five wrong passwords lock password checks for the lockout time (2 s under --policy-fast). The lockout still refuses the right password at 1.0 s of its 2 s, and it is not over before 2.0 s have passed since the fifth wrong password was sent.
    @Test func theLockoutStillRefusesTheRightPasswordAtOneSecondAndEndsNoEarlierThanTwoSeconds() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            for n in 1...4 { #expect(try RestartTests.wrongGuess(daemon, n).errorCode == .wrongPassword, "guess \(n)") }
            let phase = daemon.pauseToRandomTickPhase()
            let watch = Stopwatch()
            #expect(try RestartTests.wrongGuess(daemon, 5).errorCode == .wrongPassword)
            pause(1.0 - watch.elapsed)
            let refused = try daemon.send(.unblock, domain: "reddit.com", password: Self.password)
            #expect(refused.errorCode == .lockedOut, "the right password was accepted \(watch.elapsed) s into the 2 s lockout (fifth wrong password \(phase) s into a tick)")
            let ended = waitUntil(timeout: 3.0, interval: 0.02) { (try? daemon.status().lockoutSecondsRemaining) == nil }
            let endedAt = watch.elapsed
            #expect(ended != nil, "the lockout never ended")
            #expect(endedAt >= 2.0, "the lockout ended \(endedAt) s after the fifth wrong password (fifth wrong password \(phase) s into a tick)")
            #expect(endedAt <= 3.5)
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
        }
    }

    // MARK: Frozen daemon

    // 03 § DaemonRuntime "Tick" step 1: elapsed time is MEASURED with a clock that keeps running while the Mac sleeps; it is not counted in ticks. A daemon frozen with SIGSTOP for 1.5 s in the middle of a 2 s countdown (like a Mac that slept) must remove the site within 0.8 s of being resumed, because the frozen time counts. A daemon that counted ticks would have counted only the ticks before the freeze and would need about 1.7 s more.
    @Test func timeSpentFrozenCountsTowardTheCountdown() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let watch = Stopwatch()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            pause(0.3 - watch.elapsed)
            daemon.freeze()
            // The daemon is resumed whatever happens next, so a failing expectation never leaves a stopped process behind.
            defer { daemon.resume() }
            pause(1.5)
            #expect(daemon.hostsText() == blocked, "a frozen daemon cannot have changed the file")
            daemon.resume()
            let resumed = Stopwatch()
            let removed = waitUntil(timeout: 3.0, interval: 0.01) { daemon.hostsText() == ExpectedHosts.idleText }
            let afterResume = resumed.elapsed
            let total = watch.elapsed
            #expect(removed != nil, "the site was still blocked \(afterResume) s after the daemon was resumed")
            #expect(afterResume < 0.8, "the site went \(afterResume) s after the resume: the 1.5 s the daemon spent frozen were not counted")
            #expect(total >= 2.0, "the site went \(total) s after the unblock request, before the 2 s delay was over")
            let status = try daemon.status()
            #expect(status.blocked.isEmpty)
        }
    }

    // MARK: Catch-up before every command

    // 03 § DaemonRuntime "Before every command": every countdown is advanced by the time since the last tick or command, anything finished is applied (saved and enforced as a tick would), and now becomes the last tick time. The tick here never fires (every 60 s), so only commands move the clock. Two things follow. (1) A countdown started by a command is not charged for the idle time before it existed: after 1.6 s of idle time a new 2 s countdown still shows 2 s, and at 1.0 s it has not finished. (2) A finished countdown is applied by the next command before it answers: after the 2 s a status request returns with the site gone from the answer and from the hosts file.
    @Test func aCountdownIsNotChargedForTimeBeforeItStartedAndTheNextCommandAppliesAFinishedOne() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            pause(1.6)
            let watch = Stopwatch()
            let reply = try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            #expect(reply.status?.blocked.first?.unblockSecondsRemaining == 2, "the new countdown was charged for the idle time before it: \(String(describing: reply.status?.blocked.first?.unblockSecondsRemaining)) s left at the start")
            pause(1.0 - watch.elapsed)
            let midway = try daemon.status()
            #expect(midway.blocked.map(\.domain) == ["reddit.com"], "the countdown finished at about 1 s of its 2 s")
            let left = try #require(midway.blocked.first?.unblockSecondsRemaining)
            #expect((1...2).contains(left), "about 1 s should be left, the display shows \(left)")
            #expect(daemon.hostsText() == blocked)

            pause(2.1 - watch.elapsed)
            let done = try daemon.status()
            #expect(done.blocked.isEmpty, "the command after the delay did not apply the finished unblock")
            #expect(daemon.hostsText() == ExpectedHosts.idleText, "the removal must be on disk when that command has answered")
            let saved = try #require(daemon.stateObject())
            #expect((saved["blocked"] as? [Any])?.isEmpty == true, "the finished unblock is saved")
        }
    }

    // 03 § DaemonRuntime "Before every command": "no stretch of time is counted twice". Every command catches the countdown up and records now as the last tick time, so the tick that follows measures only the time since that command. If a command forgot to record it, each stretch would be counted by the command and again by the tick, and a countdown would run at up to double speed. Here a status request is sent every 10 ms during a 2 s unblock; the site must still not be gone before 2.0 s.
    @Test func manyCommandsDuringACountdownDoNotCountTheSameTimeTwice() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let phase = daemon.pauseToRandomTickPhase()
            let watch = Stopwatch()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            var goneAt: Double?
            var polls = 0
            while watch.elapsed < 5.0 {
                let status = try daemon.status()
                polls += 1
                if status.blocked.isEmpty {
                    goneAt = watch.elapsed
                    break
                }
                pause(0.01)
            }
            let gone = try #require(goneAt, "the site was still blocked after 5 s and \(polls) status requests")
            #expect(gone >= 2.0, "the site was gone \(gone) s after the request, after \(polls) status requests: some time was counted twice (request \(phase) s into a tick)")
            #expect(gone < 4.0)
            #expect(polls >= 30, "only \(polls) status requests were sent during the countdown, too few to test anything")
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
        }
    }

    // The same rule for a delay change (01 § Commands, setDelay). With no tick, the status request after the 2 s wait applies the 1 s delay; at 1.0 s the delay is still 2.
    @Test func aPendingDelayChangeIsAppliedByTheNextCommandAfterTheWaitAndNotBefore() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            pause(1.0)
            let watch = Stopwatch()
            try daemon.send(.setDelay, password: Self.password, seconds: 1).requireOK()
            pause(1.0 - watch.elapsed)
            let midway = try daemon.status()
            #expect(midway.delaySeconds == 2, "applied after \(watch.elapsed) s of the 2 s wait")
            #expect(midway.pendingDelay != nil)
            pause(2.1 - watch.elapsed)
            let done = try daemon.status()
            #expect(done.delaySeconds == 1, "the command after the wait did not apply the delay change")
            #expect(done.pendingDelay == nil)
        }
    }

    // 02 § Engine "Finished-but-uncleared lockout" and 03 § DaemonRuntime "Before every command": with no tick, the right password is still refused at 1.0 s of the 2 s lockout, and is accepted by the first command after the lockout is over (the catch-up ends it).
    @Test func aLockoutIsEndedByTheNextCommandAfterItsTimeAndNotBefore() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let watch = Stopwatch()
            for n in 1...5 { #expect(try RestartTests.wrongGuess(daemon, n).errorCode == .wrongPassword, "guess \(n)") }
            pause(1.0 - watch.elapsed)
            let refused = try daemon.send(.unblock, domain: "reddit.com", password: Self.password)
            #expect(refused.errorCode == .lockedOut, "accepted at \(watch.elapsed) s of a 2 s lockout")
            pause(2.2 - watch.elapsed)
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            let status = try daemon.status()
            #expect(status.lockoutSecondsRemaining == nil)
        }
    }
}
