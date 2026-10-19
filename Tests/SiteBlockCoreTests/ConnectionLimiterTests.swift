import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § ConnectionLimiter: init(perUserLimit: 4, total: 32, rootReserved: 4);
// admit lets root in while fewer than `total` connections are open in all, and lets a non-root user in while it holds fewer than
// `perUserLimit` and fewer than `total - rootReserved` are open in all (root's included), so the last `rootReserved` slots are always
// free for root; UInt32.max is an ordinary non-root user; release frees one slot, and a release for a user with nothing open does
// nothing, so no count goes below zero. The limiter is thread-safe. User ids are passed in directly, so no socket is needed.

// How many times `admit` says yes for this user id before it says no, trying at most `limit` times.
private func admits(_ limiter: ConnectionLimiter, uid: uid_t, upTo limit: Int = 1000) -> Int {
    var count = 0
    while count < limit, limiter.admit(uid: uid) { count += 1 }
    return count
}

// Fills the limiter with non-root connections, four per user id, from the given first id upward, until `total` are open. Returns the ids used.
// A limiter that refuses what it should admit would never reach `total`, so the walk stops after 50 users instead of looping forever
// (a loop that records a failure on every pass would otherwise fill the disk with failure reports).
@discardableResult
private func fillNonRoot(_ limiter: ConnectionLimiter, total: Int, firstUID: uid_t = 1000) -> [uid_t] {
    var used: [uid_t] = []
    var open = 0
    var uid = firstUID
    while open < total, used.count < 50 {
        let wanted = min(4, total - open)
        let granted = admits(limiter, uid: uid, upTo: wanted)
        #expect(granted == wanted, "test setup: user \(uid) should have been admitted \(wanted) times, got \(granted)")
        open += granted
        used.append(uid)
        uid += 1
    }
    return used
}

@Suite struct ConnectionLimiterTests {
    // MARK: one user

    @Test(arguments: [uid_t(1), 501, 502, 65_534])
    func aNonRootUserIsAdmittedExactlyFourTimesAndThenRefused(uid: uid_t) {
        let limiter = ConnectionLimiter()
        for attempt in 1...4 { #expect(limiter.admit(uid: uid), "admit number \(attempt) for user \(uid) should succeed") }
        #expect(!limiter.admit(uid: uid), "the fifth admit must be refused")
        #expect(!limiter.admit(uid: uid), "and so must the sixth: a refusal takes no slot")
    }

    // A refused admit takes nothing, so one release after it frees exactly one place, not two.
    @Test func releaseFreesExactlyOneSlotForThatUser() {
        let limiter = ConnectionLimiter()
        #expect(admits(limiter, uid: 501) == 4)
        #expect(!limiter.admit(uid: 501))
        limiter.release(uid: 501)
        #expect(limiter.admit(uid: 501), "one release frees one slot")
        #expect(!limiter.admit(uid: 501), "and only one")
        limiter.release(uid: 501)
        limiter.release(uid: 501)
        #expect(admits(limiter, uid: 501) == 2)
    }

    // Each user id has its own count of four.
    @Test func eachUserHasItsOwnFourSlots() {
        let limiter = ConnectionLimiter()
        #expect(admits(limiter, uid: 501) == 4)
        #expect(admits(limiter, uid: 502) == 4)
        #expect(!limiter.admit(uid: 501))
        // 502's release frees 502's slot, and 501 is still full.
        limiter.release(uid: 502)
        #expect(!limiter.admit(uid: 501))
        #expect(limiter.admit(uid: 502))
    }

    // MARK: stray releases

    // "a release for a user with nothing open does nothing, so no count goes below zero": if a stray release were counted, the user would
    // get five admits afterwards.
    @Test func aStrayReleaseForAUserWithNothingOpenDoesNothing() {
        let limiter = ConnectionLimiter()
        limiter.release(uid: 501)
        limiter.release(uid: 501)
        limiter.release(uid: 501)
        #expect(admits(limiter, uid: 501) == 4, "stray releases must not make room for a fifth connection")
    }

    @Test func aStrayReleaseForAnotherUserDoesNotFreeAFullUsersSlot() {
        let limiter = ConnectionLimiter()
        #expect(admits(limiter, uid: 501) == 4)
        limiter.release(uid: 502)
        #expect(!limiter.admit(uid: 501), "user 502 had nothing open, so releasing for it must not free one of 501's slots")
        #expect(admits(limiter, uid: 502) == 4, "and 502 still has all four of its own")
    }

    // More releases than admits leave the user with nothing open and never with credit.
    @Test func releasingMoreOftenThanAdmittedLeavesNoCredit() {
        let limiter = ConnectionLimiter()
        #expect(admits(limiter, uid: 501, upTo: 2) == 2)
        for _ in 0..<5 { limiter.release(uid: 501) }
        #expect(admits(limiter, uid: 501) == 4)
    }

    // The same for root: a stray root release must not lower the open count below zero and so let root in past the total of 32.
    @Test func aStrayReleaseForRootDoesNotRaiseRootsLimit() {
        let limiter = ConnectionLimiter()
        for _ in 0..<3 { limiter.release(uid: 0) }
        #expect(admits(limiter, uid: 0) == 32, "root is limited by the total of 32, however many stray releases came first")
    }

    // A stray release for a non-root user must not lower the total either, which would let non-root in past 28.
    @Test func strayReleasesDoNotRaiseTheNonRootCeilingOf28() {
        let limiter = ConnectionLimiter()
        for uid in uid_t(1)...uid_t(10) { limiter.release(uid: uid) }
        #expect(fillNonRoot(limiter, total: 28).count == 7)
        #expect(!limiter.admit(uid: 5000), "28 non-root connections are open, so a user with none open is refused")
    }

    // MARK: the totals

    // The non-root ceiling is total - rootReserved = 28. With four per user it takes seven users to reach it; an eighth is refused even
    // though it holds nothing, and when one connection closes anyone with room may take its place.
    @Test func nonRootUsersTogetherAreCappedAt28AndAnEighthUserIsRefused() {
        let limiter = ConnectionLimiter()
        let users = fillNonRoot(limiter, total: 28)
        #expect(users.count == 7)
        #expect(!limiter.admit(uid: 9000), "a user with nothing open is refused once 28 non-root connections are open")
        for uid in users { #expect(!limiter.admit(uid: uid), "user \(uid) is at its own limit as well") }
        limiter.release(uid: users[3])
        #expect(limiter.admit(uid: 9000), "a place opened up, so a new user may take it")
        #expect(!limiter.admit(uid: 9001), "and only that one")
    }

    // The same ceiling for two users, with the per-user limit raised so that two users can reach it: together they hold at most 28.
    @Test func twoNonRootUsersTogetherAreCappedAt28WhenThePerUserLimitAllowsIt() {
        let limiter = ConnectionLimiter(perUserLimit: 20, total: 32, rootReserved: 4)
        #expect(admits(limiter, uid: 501) == 20, "the first user may take its 20")
        #expect(admits(limiter, uid: 502) == 8, "the second can take only what is left under 28")
        #expect(!limiter.admit(uid: 501) && !limiter.admit(uid: 502) && !limiter.admit(uid: 503))
        limiter.release(uid: 501)
        #expect(limiter.admit(uid: 502), "27 are open, so one more fits")
        #expect(!limiter.admit(uid: 502), "28 are open again")
    }

    // The point of the reserve: with 28 non-root connections open, root still gets in four more, up to the total of 32, and then not a fifth.
    @Test func withTwentyEightNonRootConnectionsOpenRootStillGetsFourMoreAndThenIsRefused() {
        let limiter = ConnectionLimiter()
        fillNonRoot(limiter, total: 28)
        for attempt in 1...4 { #expect(limiter.admit(uid: 0), "root admit number \(attempt) should use a reserved slot") }
        #expect(!limiter.admit(uid: 0), "32 connections are open, the limit")
        // A freed non-root slot is not a slot for a non-root user while root's reserved ones are in use: 31 are open, which is above 28.
        limiter.release(uid: 1000)
        #expect(!limiter.admit(uid: 9000), "31 are open, over the non-root ceiling of 28")
        #expect(limiter.admit(uid: 0), "but root may take the one free place")
        #expect(!limiter.admit(uid: 0))
    }

    // Root first: root's open connections count toward the 28 that non-root users may not pass.
    @Test func withTenRootConnectionsOpenNonRootUsersAreCappedWhenTheTotalReaches28() {
        let limiter = ConnectionLimiter()
        #expect(admits(limiter, uid: 0, upTo: 10) == 10)
        var granted = 0
        var uid: uid_t = 1000
        while uid < 1020 {
            granted += admits(limiter, uid: uid)
            uid += 1
        }
        #expect(granted == 18, "10 root + 18 non-root = 28 open; non-root got \(granted)")
        #expect(!limiter.admit(uid: 4000))
        // Root is still served up to 32 in all, which is 4 more.
        #expect(admits(limiter, uid: 0) == 4)
    }

    // Root alone can fill the whole total of 32.
    @Test func rootAloneCanUseAllThirtyTwoSlots() {
        let limiter = ConnectionLimiter()
        #expect(admits(limiter, uid: 0) == 32)
        #expect(!limiter.admit(uid: 501), "no slot is left for anyone")
        limiter.release(uid: 0)
        #expect(!limiter.admit(uid: 501), "31 are open, above the non-root ceiling")
        #expect(admits(limiter, uid: 0) == 1)
    }

    // Releasing root's connections frees root's own slots and does not hand them to a non-root user who is over the ceiling.
    @Test func releasingRootConnectionsLowersTheCountForNonRootUsersToo() {
        let limiter = ConnectionLimiter()
        #expect(admits(limiter, uid: 0, upTo: 28) == 28)
        #expect(!limiter.admit(uid: 501), "28 root connections already reach the non-root ceiling")
        limiter.release(uid: 0)
        #expect(limiter.admit(uid: 501), "27 are open, so a non-root user fits")
    }

    // MARK: UInt32.max

    // The server uses UInt32.max when it cannot read the peer's user id. It is an ordinary non-root user: four slots of its own.
    @Test func theMaximumUserIDIsAnOrdinaryNonRootUserWithFourSlots() {
        let limiter = ConnectionLimiter()
        #expect(admits(limiter, uid: UInt32.max) == 4)
        #expect(!limiter.admit(uid: UInt32.max))
        #expect(admits(limiter, uid: 501) == 4, "and it does not use up another user's slots")
        limiter.release(uid: UInt32.max)
        #expect(limiter.admit(uid: UInt32.max))
    }

    // It gets no root privileges: when 28 other connections are open it is refused, while root is let in.
    @Test func theMaximumUserIDIsRefusedAtTheNonRootCeilingWhereRootIsStillAdmitted() {
        let limiter = ConnectionLimiter()
        fillNonRoot(limiter, total: 28)
        #expect(!limiter.admit(uid: UInt32.max))
        #expect(limiter.admit(uid: 0))
    }

    // And its connections count toward the 28 like anyone's.
    @Test func theMaximumUserIDsConnectionsCountTowardTheNonRootCeiling() {
        let limiter = ConnectionLimiter()
        #expect(admits(limiter, uid: UInt32.max) == 4)
        fillNonRoot(limiter, total: 24)
        #expect(!limiter.admit(uid: 9000), "4 + 24 = 28 non-root connections are open")
    }

    // MARK: custom limits

    @Test func theLimitsGivenToTheInitializerAreTheOnesUsed() {
        let limiter = ConnectionLimiter(perUserLimit: 2, total: 5, rootReserved: 1)
        #expect(admits(limiter, uid: 501) == 2, "per-user limit 2")
        #expect(admits(limiter, uid: 502) == 2)
        #expect(admits(limiter, uid: 503) == 0, "total - rootReserved = 4 are open")
        #expect(admits(limiter, uid: 0) == 1, "root takes the one reserved slot, which makes the total of 5")
        #expect(!limiter.admit(uid: 0))
    }

    @Test(arguments: [(1, 3, 0, 3), (3, 10, 2, 8), (10, 6, 6, 0), (5, 8, 1, 7), (4, 4, 0, 4)])
    func theNonRootCeilingIsTotalMinusRootReservedWhateverTheLimits(perUserLimit: Int, total: Int, rootReserved: Int, expectedNonRoot: Int) {
        let limiter = ConnectionLimiter(perUserLimit: perUserLimit, total: total, rootReserved: rootReserved)
        var granted = 0
        for uid in uid_t(1000)..<uid_t(1100) { granted += admits(limiter, uid: uid) }
        #expect(granted == expectedNonRoot, "limits \(perUserLimit)/\(total)/\(rootReserved): non-root got \(granted)")
        // Root then takes whatever is left of the total.
        #expect(admits(limiter, uid: 0) == total - expectedNonRoot)
    }

    @Test func aPerUserLimitOfZeroAdmitsNoNonRootUserButRootIsStillServed() {
        let limiter = ConnectionLimiter(perUserLimit: 0, total: 6, rootReserved: 2)
        #expect(admits(limiter, uid: 501) == 0)
        #expect(admits(limiter, uid: UInt32.max) == 0)
        #expect(admits(limiter, uid: 0) == 6)
    }

    // MARK: concurrency

    // Keeps a running count of connections the test itself is holding per user id, behind its own lock.
    private final class LiveCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var byUser: [uid_t: Int] = [:]
        private var violations: [String] = []
        var refusals = 0
        var admissions = 0

        // Records that `uid` was admitted and checks the limits against the connections the test itself still holds. The test removes a
        // connection from its own count BEFORE it calls release, so these counts can never be higher than the limiter's own: a count over
        // the limit seen here means the limiter let too many in.
        func admitted(_ uid: uid_t) {
            lock.lock()
            defer { lock.unlock() }
            admissions += 1
            byUser[uid, default: 0] += 1
            let nonRoot = byUser.filter { $0.key != 0 }.values.reduce(0, +)
            let total = nonRoot + byUser[0, default: 0]
            if uid != 0, byUser[uid, default: 0] > 4 { violations.append("user \(uid) holds \(byUser[uid, default: 0])") }
            if nonRoot > 28 { violations.append("\(nonRoot) non-root connections are open") }
            if total > 32 { violations.append("\(total) connections are open") }
        }

        // Records that the test is about to release one of `uid`'s connections.
        func releasing(_ uid: uid_t) {
            lock.lock()
            byUser[uid, default: 0] -= 1
            lock.unlock()
        }

        // Records a refusal.
        func refused() {
            lock.lock()
            refusals += 1
            lock.unlock()
        }

        var problems: [String] {
            lock.lock()
            defer { lock.unlock() }
            return violations
        }
    }

    // A small seeded random generator (SplitMix64) so each thread makes the same choices on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        // Produces the next 64 random bits.
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // Eight threads admit and release at the same time, over a few shared user ids including root and UInt32.max. While they run, the limits
    // are never exceeded, and when they are done and have given everything back, every count is back where it started: a new user gets exactly
    // four slots, root gets exactly 32, and seven new users fill the 28 non-root slots exactly. A lost update (a count off by one) or a
    // dictionary corrupted by two threads would show as a different number here, or as a crash.
    @Test func eightThreadsAdmittingAndReleasingConcurrentlyKeepEveryCountConsistent() {
        let limiter = ConnectionLimiter()
        let live = LiveCounts()
        let uids: [uid_t] = [1, 2, 3, 0, UInt32.max, 501]
        let group = DispatchGroup()
        for worker in 0..<8 {
            group.enter()
            // Each worker gets its own thread rather than a slot in the shared dispatch pool. The other tests run in parallel and many of them block pool threads while they wait (for a sandbox daemon, for example); on a small machine such as GitHub's runners the pool filled up, the workers never started, and this test timed out although the limiter was fine.
            Thread {
                defer { group.leave() }
                var rng = SeededGenerator(state: UInt64(worker) &+ 1)
                var held: [uid_t] = []
                for _ in 0..<20_000 {
                    if held.isEmpty || Int.random(in: 0..<10, using: &rng) < 6 {
                        let uid = uids.randomElement(using: &rng)!
                        if limiter.admit(uid: uid) {
                            live.admitted(uid)
                            held.append(uid)
                        } else {
                            live.refused()
                        }
                    } else {
                        let uid = held.remove(at: Int.random(in: 0..<held.count, using: &rng))
                        live.releasing(uid)
                        limiter.release(uid: uid)
                    }
                }
                for uid in held {
                    live.releasing(uid)
                    limiter.release(uid: uid)
                }
            }.start()
        }
        // A limiter without its lock can corrupt its own dictionary and then spin forever. Waiting with a limit turns that into a failure
        // that names the cause, instead of a test run that never ends (a correct limiter finishes this in well under a second).
        // 180 seconds, not 60: the full suite now runs many integration tests and compiles at the same time, and on a loaded machine (or GitHub's slower runners) the eight workers took longer than 60 seconds without anything being wrong. A real deadlock never finishes, so a longer limit still catches it.
        guard group.wait(timeout: .now() + 180) == .success else {
            Issue.record("the eight workers did not finish within 180 seconds: the limiter deadlocked or spun, which points to a data race inside it")
            return
        }
        #expect(live.problems.isEmpty, "limits exceeded under concurrency: \(live.problems.prefix(3))")
        #expect(live.admissions > 1000 && live.refusals > 1000, "the threads must really have contended: \(live.admissions) admitted, \(live.refusals) refused")
        // Everything has been given back, so the limiter must behave like a new one.
        #expect(admits(limiter, uid: 7777) == 4, "a fresh user must get exactly four slots")
        for _ in 0..<4 { limiter.release(uid: 7777) }
        #expect(admits(limiter, uid: 0) == 32, "root must get exactly 32 slots")
        for _ in 0..<32 { limiter.release(uid: 0) }
        #expect(fillNonRoot(limiter, total: 28, firstUID: 100).count == 7)
        #expect(!limiter.admit(uid: 9000))
        // The users the threads worked with are back to four slots each too (released first so the total ceiling does not interfere).
        for uid in uid_t(100)...uid_t(106) { for _ in 0..<4 { limiter.release(uid: uid) } }
        for uid in [uid_t(1), 2, 3, UInt32.max, 501] { #expect(admits(limiter, uid: uid, upTo: 5) == 4, "user \(uid) is not back to four slots") }
    }
}
