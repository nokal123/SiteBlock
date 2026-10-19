import Foundation
import Testing
import SiteBlockCore

// The Engine's temporary unblock commands. Expected values come from Design Plans/02-core-components.md § Engine ("Temporary unblock commands" with its
// eight checks in order, "Command rules" for add, unblock and the cancel commands, "Argument rule", "Password check rule", "Lockout wording") and
// 01-overview-and-data.md § Wire Protocol (Commands, error codes), § Data Model (TemporaryUnblock) and § Fixed Policy Values. The messages that the design
// gives word for word are compared word for word; the others are compared by the durations they name.

// MARK: approval

@Suite struct TemporaryUnblockApprovalTests {
    // 02 § Engine, step 8: "Set temporaryUnblock ... startsIn = Countdown(seconds: start wait) and window = Countdown(seconds: seconds)". The site stays on the list.
    @Test func approvalStoresTwoCountdownsOfTheChosenLengthsAndKeepsTheSiteOnTheList() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        let response = engine.temporarily("reddit.com", seconds: 1800, start: 3600)
        expectSuccess(response)
        #expect(engine.temporaryUnblock(of: "reddit.com") == TemporaryUnblock(startsIn: Countdown(seconds: 3600), window: Countdown(seconds: 1800)))
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com", "example.com"], "the site stays on the block list in its place")
        #expect(engine.site("reddit.com")?.pendingUnblock == nil)
        #expect(engine.temporaryUnblock(of: "example.com") == nil, "another site is not touched")
        #expect(engine.temporaryUnblock(of: "reddit.com")?.isOpen == false && engine.temporaryUnblock(of: "reddit.com")?.isFinished == false)
    }

    // 01 § Fixed Policy Values: "It is the unblock delay when none is given." The delay is the current one, whatever it is.
    @Test(arguments: [1800, 3600, 86_400, 604_800])
    func aMissingStartWaitMeansTheCurrentUnblockDelay(delay: Int) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: policyWithDelay(delay))
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: nil))
        #expect(engine.temporaryUnblock(of: "reddit.com")?.startsIn == Countdown(seconds: Double(delay)))
        #expect(engine.temporaryUnblock(of: "reddit.com")?.window == Countdown(seconds: 1800))
    }

    // 02 § Engine, step 8: 'The message reads like "reddit.com opens in 1 hour, for 30 minutes, then blocks again."' With a delay of 1 hour and no start wait that is exactly this request.
    @Test func theMessageForAOneHourWaitAndAThirtyMinuteWindowIsTheDesignsExample() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: policyWithDelay(3600))
        let response = engine.temporarily("reddit.com", seconds: 1800, start: nil)
        expectSuccess(response)
        #expect(response.message == "reddit.com opens in 1 hour, for 30 minutes, then blocks again.")
    }

    // The same wording pattern with other lengths, compared by the durations in it (written as Formatting.duration writes them), in order.
    @Test(arguments: [(7200, 14_400, ["2 hour", "4 hour"]), (1800, 300, ["30 minute", "5 minute"]), (90_000, 3600, ["1 day", "1 hour", "1 hour"]), (604_800, 14_400, ["7 day", "4 hour"])])
    func theMessageNamesTheStartWaitAndTheWindow(start: Int, window: Int, expected: [String]) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let response = engine.temporarily("reddit.com", seconds: window, start: start)
        expectSuccess(response)
        #expect(response.message?.hasPrefix("reddit.com opens in ") == true, "got: \(response.message ?? "nil")")
        #expect(response.message?.hasSuffix(", then blocks again.") == true, "got: \(response.message ?? "nil")")
        #expect(durationPairs(in: response.message ?? "") == expected, "got: \(response.message ?? "nil")")
    }

    // 02 § Engine: every reply names a path rule in its display form (`youtube.com/shorts`, domain and path joined), never the text as typed.
    @Test func theMessageForAPathRuleNamesTheRule() {
        let engine = makeEngine(policy: policyWithDelay(3600))
        expectSuccess(engine.send(.addPath, domain: "https://www.youtube.com/shorts/abc"))
        let response = engine.temporarily("youtube.com/shorts/abc", seconds: 1800, start: nil, rule: true)
        expectSuccess(response)
        #expect(response.message == "youtube.com/shorts/abc opens in 1 hour, for 30 minutes, then blocks again.")
    }

    // 01 § Wire Protocol: "status ... present on every successful response". The waiting entry reports the full window and the start wait.
    @Test func theReplyCarriesAStatusWithTheNewTemporaryUnblock() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let response = engine.temporarily("reddit.com", seconds: 1800, start: 3600)
        expectSuccess(response)
        let status = response.status?.blocked.first { $0.domain == "reddit.com" }
        #expect(status?.temporaryUnblock == TemporaryUnblockStatus(opensInSeconds: 3600, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false))
        #expect(status?.unblockSecondsRemaining == nil, "a temporary unblock is not a permanent unblock countdown")
    }

    // The site name goes through the normalizer like every other command: any spelling of the same site finds it.
    @Test(arguments: ["reddit.com", "REDDIT.COM", "www.reddit.com", "https://www.Reddit.com/r/all?x=1#top", "  reddit.com  "])
    func anySpellingOfTheSiteFindsIt(spelling: String) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily(spelling, seconds: 1800, start: 1800))
        #expect(engine.temporaryUnblock(of: "reddit.com") != nil)
    }

    // The rule text goes through the path rule parser: another spelling of the same rule finds it, and a different path or letter case is another rule.
    @Test(arguments: ["youtube.com/shorts", "https://www.youtube.com/shorts/", "YouTube.com/shorts*", "www.youtube.com/shorts?x=1#y"])
    func anySpellingOfTheRuleFindsIt(spelling: String) {
        let engine = makeEngine(policy: temporaryPolicy)
        for rule in ["youtube.com/shorts", "youtube.com/Shorts", "youtube.com/watch"] { expectSuccess(engine.send(.addPath, domain: rule)) }
        expectSuccess(engine.temporarily(spelling, seconds: 1800, start: 1800, rule: true))
        #expect(engine.temporaryUnblock(ofRule: "youtube.com", "/shorts") != nil)
        #expect(engine.temporaryUnblock(ofRule: "youtube.com", "/Shorts") == nil, "paths keep their case, so /Shorts is another rule")
        #expect(engine.temporaryUnblock(ofRule: "youtube.com", "/watch") == nil)
    }

    // 02 § Engine, Temporary unblock commands: "Every reply names the site in its normalized form (`https://www.Reddit.com/r/all` is answered as `reddit.com`) and a path rule in its display form (`youtube.com/shorts`), never the text as typed".
    @Test(arguments: ["https://www.Reddit.com/r/all?x=1", "WWW.REDDIT.COM", "  Reddit.COM  ", "http://reddit.com:8080/"])
    func theApprovalNamesTheNormalizedSiteAndNotTheTypedText(typed: String) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: policyWithDelay(3600))
        let response = engine.temporarily(typed, seconds: 1800, start: nil)
        expectSuccess(response)
        #expect(response.message == "reddit.com opens in 1 hour, for 30 minutes, then blocks again.")
    }

    @Test(arguments: ["https://www.YouTube.com/shorts/?x=1", "WWW.YOUTUBE.COM/shorts", "youtube.com/shorts*"])
    func theApprovalOfARuleNamesItsDisplayFormAndNotTheTypedText(typed: String) {
        let engine = makeEngine(policy: policyWithDelay(3600))
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        let response = engine.temporarily(typed, seconds: 1800, start: nil, rule: true)
        expectSuccess(response)
        #expect(response.message == "youtube.com/shorts opens in 1 hour, for 30 minutes, then blocks again.")
    }

    // The refusals name the normalized site too: the typed text never comes back.
    @Test func theRefusalsNameTheNormalizedSiteAndNotTheTypedText() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
        let second = engine.temporarily("https://www.Reddit.com/r/all", seconds: 900, start: 3600)
        expectFailure(second, .alreadyPending)
        #expect(second.error == "reddit.com already has a temporary unblock.")
        let unknown = engine.temporarily("https://WWW.Nowhere.example/x?y=1", seconds: 900, start: 3600)
        expectFailure(unknown, .notBlocked)
        let words = unknown.error ?? ""
        #expect(words.contains("nowhere.example") && !words.contains("Nowhere") && !words.contains("https") && !words.contains("WWW") && !words.contains("?"), "got: \(words)")
        let permanent = engine.send(.unblock, domain: "WWW.Reddit.COM", password: badPassword)
        expectFailure(permanent, .alreadyPending)
        #expect(permanent.error == "reddit.com has a temporary unblock. Keep it blocked first if you want to unblock it for good.")
    }

    // A path rule and a site are different things: the site command does not find a rule, and the rule command does not find a site.
    @Test func theSiteCommandDoesNotFindARuleAndTheRuleCommandDoesNotFindASite() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectFailure(engine.temporarily("youtube.com", seconds: 1800, start: 1800), .notBlocked)
        expectFailure(engine.temporarily("reddit.com/shorts", seconds: 1800, start: 1800, rule: true), .notBlocked)
        // A rule command with a site name that has no path is a path problem, as for addPath.
        expectFailure(engine.temporarily("reddit.com", seconds: 1800, start: 1800, rule: true), .invalidPath)
    }

    // 02 § Engine, Password check rule, step 4: "If the password is right, reset failedAttempts to 0". A right password in a valid temporary unblock request counts as a right password.
    @Test func aRightPasswordInAnApprovedRequestResetsTheFailedAttempts() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        for _ in 0..<2 { expectFailure(engine.send(.unblock, domain: "reddit.com", password: badPassword), .wrongPassword) }
        #expect(engine.state.failedAttempts == 2)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
        #expect(engine.state.failedAttempts == 0)
    }

    // The two commands are independent: a site and a rule can each have their own temporary unblock at the same time.
    @Test func aSiteAndARuleCanEachHaveTheirOwnTemporaryUnblock() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 900, start: 7200, rule: true))
        #expect(engine.temporaryUnblock(of: "reddit.com") == TemporaryUnblock(startsIn: Countdown(seconds: 1800), window: Countdown(seconds: 1800)))
        #expect(engine.temporaryUnblock(ofRule: "youtube.com", "/shorts") == TemporaryUnblock(startsIn: Countdown(seconds: 7200), window: Countdown(seconds: 900)))
    }

    // A temporary unblock is not restricted to a certain caller: like unblock, it is the password that protects it, so root and an ordinary user are both accepted.
    @Test(arguments: [uid_t(0), uid_t(501), UInt32.max])
    func anyCallerWithThePasswordMayAskForOne(uid: uid_t) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800, uid: uid))
    }
}

// MARK: the order of the checks

// How the engine's failure state is prepared before a refused request: nothing special, four wrong passwords already counted (one more would lock out), or a lockout running.
enum FailureMode: CaseIterable, CustomTestStringConvertible, Sendable {
    case fresh, fourWrongAttempts, lockedOut

    var testDescription: String {
        switch self {
        case .fresh: return "no earlier failures"
        case .fourWrongAttempts: return "four wrong passwords counted"
        case .lockedOut: return "locked out"
        }
    }

    // Brings the scenario engine into this mode through real commands (a wrong password on an ordinary site).
    func prepare(_ engine: Engine) {
        switch self {
        case .fresh: break
        case .fourWrongAttempts: for _ in 0..<4 { expectFailure(engine.send(.unblock, domain: "plain.example", password: badPassword), .wrongPassword) }
        case .lockedOut: exhaustPasswordAttempts(engine, domain: "plain.example")
        }
    }
}

// One request that must be refused before the password is looked at, with the code the design gives for it.
struct RefusalCase: Sendable, CustomTestStringConvertible {
    let name: String
    let request: Request
    let code: ErrorCode

    var testDescription: String { name }

    // A temporaryUnblock or temporaryUnblockPath request with a wrong password unless told otherwise.
    private static func make(_ name: String, _ code: ErrorCode, rule: Bool = false, domain: String?, password: String? = badPassword, seconds: Int? = 1800, start: Int? = nil) -> RefusalCase {
        RefusalCase(name: name, request: Request(command: rule ? .temporaryUnblockPath : .temporaryUnblock, domain: domain, password: password, seconds: seconds, startSeconds: start), code: code)
    }

    // 02 § Engine, Temporary unblock commands, steps 1 to 6, one or more requests per step, in the scenario of `makeScenarioEngine`.
    static let all: [RefusalCase] = [
        // Step 1: a missing field is a badRequest, and it comes before everything after it.
        make("site: domain missing", .badRequest, domain: nil),
        make("site: password missing", .badRequest, domain: "plain.example", password: nil),
        make("site: seconds missing", .badRequest, domain: "plain.example", seconds: nil),
        make("site: all three missing", .badRequest, domain: nil, password: nil, seconds: nil),
        make("rule: domain missing", .badRequest, rule: true, domain: nil),
        make("rule: password missing", .badRequest, rule: true, domain: "ruleplain.example/shorts", password: nil),
        make("rule: seconds missing", .badRequest, rule: true, domain: "ruleplain.example/shorts", seconds: nil),
        make("site: missing seconds beats an unknown site", .badRequest, domain: "nowhere.example", seconds: nil),
        make("site: missing password beats a bad name", .badRequest, domain: "1.2.3.4", password: nil),
        make("site: missing seconds beats a pending unblock", .badRequest, domain: "pending.example", seconds: nil),
        make("rule: missing password beats a bad rule text", .badRequest, rule: true, domain: "ruleplain.example", password: nil),
        // Step 2: a name or rule text that cannot be used, before the lookup and before the window is judged.
        make("site: IP address", .invalidDomain, domain: "1.2.3.4"),
        make("site: localhost", .invalidDomain, domain: "localhost"),
        make("site: underscore", .invalidDomain, domain: "my_site.com"),
        make("site: one label", .invalidDomain, domain: "reddit"),
        make("site: empty text", .invalidDomain, domain: ""),
        make("site: bad name beats a window out of range", .invalidDomain, domain: "1.2.3.4", seconds: 1),
        make("rule: host problem", .invalidDomain, rule: true, domain: "1.2.3.4/shorts"),
        make("rule: host problem beats a path problem", .invalidDomain, rule: true, domain: "1.2.3.4/a b"),
        make("rule: no path", .invalidPath, rule: true, domain: "ruleplain.example"),
        make("rule: only a slash", .invalidPath, rule: true, domain: "ruleplain.example/"),
        make("rule: space in the path", .invalidPath, rule: true, domain: "ruleplain.example/a b"),
        make("rule: star in the middle", .invalidPath, rule: true, domain: "ruleplain.example/sho*rts"),
        make("rule: bad path beats a window out of range", .invalidPath, rule: true, domain: "ruleplain.example", seconds: 1),
        // Step 3: nothing by that name.
        make("site: unknown", .notBlocked, domain: "nowhere.example"),
        make("site: unknown beats a window out of range", .notBlocked, domain: "nowhere.example", seconds: 1),
        make("site: only a rule exists for that domain", .notBlocked, domain: "ruleplain.example"),
        make("rule: unknown domain", .notBlocked, rule: true, domain: "nowhere.example/shorts"),
        make("rule: another path on a known domain", .notBlocked, rule: true, domain: "ruleplain.example/other"),
        make("rule: only the whole site exists", .notBlocked, rule: true, domain: "plain.example/shorts"),
        // Step 4: it already has an unblock of either kind, and that comes before the window and the start wait are judged.
        make("site: permanent unblock waiting", .alreadyPending, domain: "pending.example"),
        make("site: temporary unblock waiting", .alreadyPending, domain: "temp.example"),
        make("rule: permanent unblock waiting", .alreadyPending, rule: true, domain: "rulepending.example/shorts"),
        make("rule: temporary unblock waiting", .alreadyPending, rule: true, domain: "ruletemp.example/shorts"),
        make("site: pending beats a window out of range", .alreadyPending, domain: "pending.example", seconds: 1, start: 1),
        make("site: temporary beats a start wait out of range", .alreadyPending, domain: "temp.example", start: 1),
        // Step 5: the window.
        make("site: window one second short", .invalidDuration, domain: "plain.example", seconds: 299),
        make("site: window one second long", .invalidDuration, domain: "plain.example", seconds: 14_401),
        make("site: window zero", .invalidDuration, domain: "plain.example", seconds: 0),
        make("site: window negative", .invalidDuration, domain: "plain.example", seconds: -1),
        make("site: window Int.max", .invalidDuration, domain: "plain.example", seconds: Int.max),
        make("site: window Int.min", .invalidDuration, domain: "plain.example", seconds: Int.min),
        make("rule: window one second short", .invalidDuration, rule: true, domain: "ruleplain.example/shorts", seconds: 299),
        make("rule: window one second long", .invalidDuration, rule: true, domain: "ruleplain.example/shorts", seconds: 14_401),
        // Step 6: the start wait.
        make("site: start wait one second below the delay", .invalidDuration, domain: "plain.example", start: 1799),
        make("site: start wait one second above seven days", .invalidDuration, domain: "plain.example", start: 604_801),
        make("site: start wait zero", .invalidDuration, domain: "plain.example", start: 0),
        make("site: start wait negative", .invalidDuration, domain: "plain.example", start: -1800),
        make("site: start wait Int.max", .invalidDuration, domain: "plain.example", start: Int.max),
        make("site: start wait Int.min", .invalidDuration, domain: "plain.example", start: Int.min),
        make("site: window and start wait both out of range", .invalidDuration, domain: "plain.example", seconds: 1, start: 1),
        make("rule: start wait one second below the delay", .invalidDuration, rule: true, domain: "ruleplain.example/shorts", start: 1799),
        make("rule: start wait one second above seven days", .invalidDuration, rule: true, domain: "ruleplain.example/shorts", start: 604_801),
        // The permanent unblock commands refuse an entry that has a temporary unblock, before the password.
        RefusalCase(name: "unblock: site has a temporary unblock", request: Request(command: .unblock, domain: "temp.example", password: badPassword), code: .alreadyPending),
        RefusalCase(name: "unblockPath: rule has a temporary unblock", request: Request(command: .unblockPath, domain: "ruletemp.example/shorts", password: badPassword), code: .alreadyPending),
    ]
}

@Suite struct TemporaryUnblockCheckOrderTests {
    // 02 § Engine: "a request that is malformed or out of range is refused before any lockout or password check, so it never counts as a wrong password."
    // 05 § Unit Tests: "a request that fails any check before the password check, even with a wrong password, leaves failedAttempts at 0, and gets that
    // check's error even during a lockout". Every refusal below is sent with a wrong password in three situations, and must change nothing at all
    // (the whole state is compared, so a stray failure count, a started lockout or a half-set unblock would all show).
    @Test(arguments: FailureMode.allCases, RefusalCase.all)
    func aRefusedRequestGetsItsOwnCodeAndChangesNothing(mode: FailureMode, refusal: RefusalCase) {
        let engine = makeScenarioEngine()
        mode.prepare(engine)
        let before = engine.state
        let response = engine.handle(refusal.request, peerUID: 501)
        expectFailure(response, refusal.code)
        #expect(engine.state == before, "a refusal must leave the state exactly as it was")
    }

    // The same refusals with the RIGHT password in place of the wrong one: a refusal never reaches the password rule, so the right password changes nothing either.
    @Test(arguments: RefusalCase.all)
    func aRefusalWithTheRightPasswordIsRefusedTheSameWay(refusal: RefusalCase) {
        let engine = makeScenarioEngine()
        var request = refusal.request
        if request.password != nil { request.password = rightPassword }
        let before = engine.state
        expectFailure(engine.handle(request, peerUID: 501), refusal.code)
        #expect(engine.state == before)
    }

    // After the refusals the failure counter is where it was: one more wrong password in a VALID request is the fifth, and starts the lockout.
    @Test func refusalsDoNotMoveTheFailureCounterSoTheNextWrongPasswordIsTheFifth() {
        let engine = makeScenarioEngine()
        FailureMode.fourWrongAttempts.prepare(engine)
        for refusal in RefusalCase.all { _ = engine.handle(refusal.request, peerUID: 501) }
        #expect(engine.state.failedAttempts == 4)
        #expect(engine.state.lockout == nil)
        expectFailure(engine.temporarily("plain.example", password: badPassword, seconds: 1800, start: 1800), .wrongPassword)
        #expect(engine.state.lockout == Countdown(seconds: 900), "the fifth wrong password starts the 15-minute lockout")
        #expect(engine.state.failedAttempts == 0)
        #expect(engine.temporaryUnblock(of: "plain.example") == nil)
    }

    // A window and a start wait that are both wrong: the window is judged first (step 5 before step 6), so the sentence is the window sentence and not the one about the delay (30 minutes).
    @Test func whenBothTheWindowAndTheStartWaitAreWrongTheSentenceIsAboutTheWindow() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let response = engine.temporarily("reddit.com", seconds: 1, start: 1)
        expectFailure(response, .invalidDuration)
        #expect(response.error == "It must stay open for at least 5 minutes.")
        let tooLong = engine.temporarily("reddit.com", seconds: 14_401, start: 1)
        expectFailure(tooLong, .invalidDuration)
        #expect(tooLong.error == "It can't stay open for more than 4 hours.")
    }
}

// MARK: the window and the start wait

@Suite struct TemporaryUnblockRangeTests {
    // 01 § Fixed Policy Values: the window is 300 to 14400 seconds. 02 § Engine, step 5: "outside minTemporarySeconds to maxTemporarySeconds, both included".
    @Test(arguments: [(299, false), (300, true), (301, true), (3600, true), (14_399, true), (14_400, true), (14_401, false), (0, false), (1, false), (-300, false), (Int.max, false), (Int.min, false)])
    func theWindowBoundsAreThreeHundredAndFourteenFourHundredBothIncluded(seconds: Int, accepted: Bool) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let before = engine.state
        let response = engine.temporarily("reddit.com", seconds: seconds, start: 1800)
        if accepted {
            expectSuccess(response)
            #expect(engine.temporaryUnblock(of: "reddit.com")?.window == Countdown(seconds: Double(seconds)))
        } else {
            expectFailure(response, .invalidDuration)
            #expect(engine.state == before)
        }
    }

    // 02 § Engine, step 5: "The sentence names the limit that was broken: "It must stay open for at least 5 minutes." for a window that is too short and "It can't stay open for more than 4 hours." for one that is too long
    // (the numbers come from the policy)." An earlier version of this test expected one sentence naming both limits; the design was corrected to name the broken limit, because the source already did and the shorter
    // sentence tells the person which way to go. Each side is pinned word for word, so the two sentences cannot be swapped or merged.
    @Test(arguments: [(299, "It must stay open for at least 5 minutes."), (0, "It must stay open for at least 5 minutes."), (-1, "It must stay open for at least 5 minutes."), (Int.min, "It must stay open for at least 5 minutes."), (14_401, "It can't stay open for more than 4 hours."), (Int.max, "It can't stay open for more than 4 hours.")])
    func theWindowSentenceNamesTheLimitThatWasBroken(seconds: Int, sentence: String) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let response = engine.temporarily("reddit.com", seconds: seconds, start: 1800)
        expectFailure(response, .invalidDuration)
        #expect(response.error == sentence)
    }

    // "(the numbers come from the policy)": under a policy with other limits the same two sentences carry those numbers, written as durations (600 s is 10 minutes, 1200 s is 20 minutes, the fast policy's 1 s is 1 second).
    @Test func theWindowSentenceCarriesTheLimitsOfThePolicy() {
        var policy = temporaryPolicy
        policy.minTemporarySeconds = 600
        policy.maxTemporarySeconds = 1200
        let engine = makeEngine(blocking: ["reddit.com"], policy: policy)
        #expect(engine.temporarily("reddit.com", seconds: 599, start: 1800).error == "It must stay open for at least 10 minutes.")
        #expect(engine.temporarily("reddit.com", seconds: 1201, start: 1800).error == "It can't stay open for more than 20 minutes.")
        let fast = makeEngine(blocking: ["reddit.com"], policy: .fastForTests)
        #expect(fast.temporarily("reddit.com", seconds: 0, start: nil).error == "It must stay open for at least 1 second.")
        #expect(fast.temporarily("reddit.com", seconds: 14_401, start: nil).error == "It can't stay open for more than 4 hours.")
    }

    // The limits are the policy's, not fixed numbers: under the fast test policy the shortest window is 1 second and the longest is still 4 hours.
    @Test(arguments: [(0, false), (1, true), (2, true), (14_400, true), (14_401, false)])
    func theFastTestPolicyAcceptsAOneSecondWindow(seconds: Int, accepted: Bool) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: .fastForTests)
        let response = engine.temporarily("reddit.com", seconds: seconds, start: nil)
        #expect(response.ok == accepted, "window \(seconds): \(response.errorCode.map(\.rawValue) ?? "ok")")
        if !accepted { expectFailure(response, .invalidDuration) }
    }

    // 01 § Fixed Policy Values: the start wait is "at least the current unblock delay and at most 604800 seconds". With the default delay of 1800:
    @Test(arguments: [(1799, false), (1800, true), (1801, true), (86_400, true), (604_799, true), (604_800, true), (604_801, false), (0, false), (-1, false), (Int.max, false), (Int.min, false)])
    func theStartWaitBoundsAreTheDelayAndSevenDaysBothIncluded(start: Int, accepted: Bool) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let before = engine.state
        let response = engine.temporarily("reddit.com", seconds: 1800, start: start)
        if accepted {
            expectSuccess(response)
            #expect(engine.temporaryUnblock(of: "reddit.com")?.startsIn == Countdown(seconds: Double(start)))
        } else {
            expectFailure(response, .invalidDuration)
            #expect(engine.state == before)
        }
    }

    // 02 § Engine, step 6: "It can't open sooner than your unblock delay of 1 hour." for a delay of 1 hour.
    @Test func theSentenceForAStartWaitBelowTheDelayIsTheDesignsExample() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: policyWithDelay(3600))
        let response = engine.temporarily("reddit.com", seconds: 1800, start: 3599)
        expectFailure(response, .invalidDuration)
        #expect(response.error == "It can't open sooner than your unblock delay of 1 hour.")
    }

    // The sentence follows the delay: another delay is named in its own words.
    @Test(arguments: [(60, "1 minute"), (1800, "30 minutes"), (7200, "2 hours"), (86_400, "1 day"), (604_800, "7 days")])
    func theStartWaitSentenceNamesTheCurrentDelay(delay: Int, words: String) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: policyWithDelay(delay))
        let response = engine.temporarily("reddit.com", seconds: 1800, start: delay - 1)
        expectFailure(response, .invalidDuration)
        #expect(durationPairs(in: response.error ?? "") == durationPairs(in: words), "got: \(response.error ?? "nil")")
    }

    // 02 § Engine, step 6: the minimum is the CURRENT delay. A shorter delay that was only requested has not taken effect, so it does not shorten the minimum.
    @Test func aPendingShorterDelayDoesNotLowerTheMinimumStartWait() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: policyWithDelay(3600))
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 1800))
        #expect(engine.state.pendingDelayChange != nil && engine.state.delaySeconds == 3600)
        expectFailure(engine.temporarily("reddit.com", seconds: 1800, start: 1800), .invalidDuration)
        expectFailure(engine.temporarily("reddit.com", seconds: 1800, start: 3599), .invalidDuration)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 3600))
    }

    // Once the shorter delay has applied (after waiting out the old one), the lower start wait is allowed and a missing one means the new delay.
    @Test func afterAShorterDelayAppliesTheLowerMinimumAndDefaultFollow() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: policyWithDelay(3600))
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 1800))
        #expect(engine.tick(elapsed: 3600))
        #expect(engine.state.delaySeconds == 1800)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: nil))
        #expect(engine.temporaryUnblock(of: "reddit.com")?.startsIn == Countdown(seconds: 1800))
    }

    // A longer delay applies at once (02 § Engine, setDelay), so the minimum rises at once and a missing start wait means the new delay.
    @Test func aLongerDelayRaisesTheMinimumStartWaitAtOnce() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 7200))
        expectFailure(engine.temporarily("reddit.com", seconds: 1800, start: 3600), .invalidDuration)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: nil))
        #expect(engine.temporaryUnblock(of: "reddit.com")?.startsIn == Countdown(seconds: 7200))
    }

    // The longest delay (7 days) equals the longest start wait, so a missing start wait is accepted and nothing can be both "default" and "too long".
    @Test func aDelayOfSevenDaysMakesTheOnlyAllowedStartWaitSevenDays() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: policyWithDelay(604_800))
        expectFailure(engine.temporarily("reddit.com", seconds: 1800, start: 604_799), .invalidDuration)
        expectFailure(engine.temporarily("reddit.com", seconds: 1800, start: 604_801), .invalidDuration)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: nil))
        #expect(engine.temporaryUnblock(of: "reddit.com")?.startsIn == Countdown(seconds: 604_800))
    }

    // The same limits hold for a path rule.
    @Test(arguments: [(299, 1800, false), (300, 1800, true), (14_400, 1800, true), (14_401, 1800, false), (1800, 1799, false), (1800, 1800, true), (1800, 604_800, true), (1800, 604_801, false)])
    func theSameLimitsApplyToAPathRule(seconds: Int, start: Int, accepted: Bool) {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        let response = engine.temporarily("youtube.com/shorts", seconds: seconds, start: start, rule: true)
        #expect(response.ok == accepted, "window \(seconds), start \(start): \(response.errorCode.map(\.rawValue) ?? "ok")")
        if !accepted { expectFailure(response, .invalidDuration) }
    }
}

// MARK: the password rule

@Suite struct TemporaryUnblockPasswordTests {
    private let hash: PasswordHash = (try? PasswordHasher.make(password: rightPassword, iterations: 1000)) ?? PasswordHash(algorithm: "", iterations: 0, salt: "", hash: "")

    // An engine built straight from a state, which is how the daemon starts after a restart or a finished recovery.
    private func engine(passwordHash: PasswordHash?, lockout: Countdown? = nil, failedAttempts: Int = 0) -> Engine {
        let site = BlockedSite(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"])
        return Engine(state: PersistedState(passwordHash: passwordHash, blocked: [site], delaySeconds: 1800, failedAttempts: failedAttempts, lockout: lockout), policy: temporaryPolicy)
    }

    // 02 § Engine, Password check rule, step 3: a wrong password adds 1 to the failed attempts and fails with wrongPassword, naming the tries left.
    @Test func aValidRequestWithAWrongPasswordCountsOneFailureAndSetsNothing() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let before = engine.state
        let response = engine.temporarily("reddit.com", password: badPassword, seconds: 1800, start: 1800)
        expectFailure(response, .wrongPassword)
        #expect(engine.state.failedAttempts == 1)
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil)
        var expected = before
        expected.failedAttempts = 1
        #expect(engine.state == expected, "nothing but the failure counter may change")
    }

    // Five wrong passwords in valid requests start the 15-minute lockout (01 § Fixed Policy Values) and reset the counter; the fifth still answers wrongPassword.
    @Test func fiveWrongPasswordsInValidRequestsStartTheLockout() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        for attempt in 1...5 {
            expectFailure(engine.temporarily("reddit.com", password: badPassword, seconds: 1800, start: 1800), .wrongPassword)
            #expect(engine.state.failedAttempts == (attempt < 5 ? attempt : 0))
        }
        #expect(engine.state.lockout == Countdown(seconds: 900))
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil)
    }

    // The wrong-password sentence says how many tries are left, and "1 try left" in the singular.
    @Test func theLastTryIsWordedInTheSingular() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        var last: Response?
        for _ in 0..<4 { last = engine.temporarily("reddit.com", password: badPassword, seconds: 1800, start: 1800) }
        #expect(last?.error?.contains("1 try left") == true, "got: \(last?.error ?? "nil")")
        #expect(last?.error?.contains("1 tries") == false)
    }

    // 02 § Engine, Password check rule, step 1: during a lockout the password is not checked at all, so even the right password gets lockedOut and nothing is set.
    @Test func aValidRequestDuringALockoutGetsLockedOutEvenWithTheRightPassword() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        exhaustPasswordAttempts(engine, domain: "example.com")
        let before = engine.state
        expectFailure(engine.temporarily("reddit.com", password: rightPassword, seconds: 1800, start: 1800), .lockedOut)
        #expect(engine.state == before, "a locked-out request changes nothing")
        // The lockout wording gives whole minutes rounded up: 15 minutes are left right after it starts.
        #expect(durationPairs(in: engine.temporarily("reddit.com", seconds: 1800, start: 1800).error ?? "").first == "15 minute")
    }

    // After the lockout has run out, the request goes through.
    @Test func afterTheLockoutEndsTheRequestIsAccepted() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        exhaustPasswordAttempts(engine, domain: "example.com")
        #expect(engine.tick(elapsed: 900))
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
    }

    // 02 § Engine, Finished-but-uncleared lockout: "a lockout whose countdown reached 0 but which the next tick has not cleared yet does not block a password check. The check clears it and proceeds."
    @Test func aFinishedButUnclearedLockoutDoesNotBlockTheRequest() {
        let spent = Countdown(remainingSeconds: 0, totalSeconds: 900)
        let right = engine(passwordHash: hash, lockout: spent)
        expectSuccess(right.temporarily("reddit.com", seconds: 1800, start: 1800))
        let wrong = engine(passwordHash: hash, lockout: spent)
        expectFailure(wrong.temporarily("reddit.com", password: badPassword, seconds: 1800, start: 1800), .wrongPassword)
    }

    // 02 § Engine, Password check rule, step 2: with no password set the request fails with notSetUp (the state after a finished recovery: sites stay blocked, the password is gone).
    @Test func withNoPasswordSetAValidRequestGetsNotSetUp() {
        let engine = engine(passwordHash: nil)
        let before = engine.state
        expectFailure(engine.temporarily("reddit.com", seconds: 1800, start: 1800), .notSetUp)
        #expect(engine.state == before)
    }

    // The checks before the password still come first when no password is set: a window out of range is invalidDuration, an unknown site is notBlocked.
    @Test func withNoPasswordSetTheEarlierChecksStillAnswerFirst() {
        let engine = engine(passwordHash: nil)
        expectFailure(engine.temporarily("reddit.com", seconds: 10, start: 1800), .invalidDuration)
        expectFailure(engine.temporarily("nowhere.example", seconds: 1800, start: 1800), .notBlocked)
        expectFailure(engine.temporarily("reddit.com", password: nil, seconds: 1800, start: 1800), .badRequest)
    }

    // The lockout has priority over "no password": the order in the password check rule is lockout, then notSetUp.
    @Test func aLockoutIsReportedBeforeAMissingPassword() {
        let engine = engine(passwordHash: nil, lockout: Countdown(seconds: 900))
        expectFailure(engine.temporarily("reddit.com", seconds: 1800, start: 1800), .lockedOut)
    }

    // Password handling is exact: passwords are compared as typed, so the same text with a different case or a trailing space is a wrong password.
    @Test(arguments: ["HUNTER22", "hunter22 ", " hunter22", "hunter2", ""])
    func theComparisonIsExact(typed: String) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectFailure(engine.temporarily("reddit.com", password: typed, seconds: 1800, start: 1800), .wrongPassword)
        #expect(engine.state.failedAttempts == 1)
    }
}

// MARK: the policy numbers

@Suite struct TemporaryUnblockPolicyTests {
    // 02 § Engine, Policy: "Policy.production must hold exactly 1800, 60, 604800, 172800, 900, 5, 210000, 500, 172800 (the uninstall minimum), 300, 14400 and 604800 (the last three are the temporary
    // unblock limits: shortest window, longest window, longest start wait)." Each of the three is checked on its own, so a failure names the field.
    @Test func productionPolicyHoldsTheDesignsTemporaryUnblockLimits() {
        #expect(Policy.production.minTemporarySeconds == 300, "the shortest window is 5 minutes")
        #expect(Policy.production.maxTemporarySeconds == 14_400, "the longest window is 4 hours")
        #expect(Policy.production.maxTemporaryStartSeconds == 604_800, "the longest start wait is 7 days")
        #expect(Policy.production.minTemporarySeconds == 5 * 60 && Policy.production.maxTemporarySeconds == 4 * 60 * 60 && Policy.production.maxTemporaryStartSeconds == 7 * 24 * 60 * 60)
    }

    // The production policy is exactly the twelve numbers of the design, in the order the design lists them, so no other field moved when the three were added.
    @Test func productionPolicyEqualsAPolicyBuiltFromAllTwelveNumbersOfTheDesign() {
        let fromDesign = Policy(defaultDelaySeconds: 1800, minDelaySeconds: 60, maxDelaySeconds: 604_800, recoverySeconds: 172_800, lockoutSeconds: 900, maxFailedAttempts: 5, pbkdf2Iterations: 210_000, maxSites: 500, minUninstallSeconds: 172_800, minTemporarySeconds: 300, maxTemporarySeconds: 14_400, maxTemporaryStartSeconds: 604_800)
        #expect(Policy.production == fromDesign)
    }

    // 02 § Engine: "Policy.fastForTests.minTemporarySeconds is 1 ... its other two temporary unblock values equal the production values."
    @Test func theFastTestPolicyHasAOneSecondShortestWindowAndTheProductionLongestValues() {
        #expect(Policy.fastForTests.minTemporarySeconds == 1)
        #expect(Policy.fastForTests.maxTemporarySeconds == Policy.production.maxTemporarySeconds && Policy.fastForTests.maxTemporarySeconds == 14_400)
        #expect(Policy.fastForTests.maxTemporaryStartSeconds == Policy.production.maxTemporaryStartSeconds && Policy.fastForTests.maxTemporaryStartSeconds == 604_800)
    }

    // The limits really are the policy's: an engine under a policy with other numbers applies those.
    @Test func theEngineAppliesTheLimitsOfItsPolicy() {
        var policy = temporaryPolicy
        policy.minTemporarySeconds = 600
        policy.maxTemporarySeconds = 1200
        policy.maxTemporaryStartSeconds = 3600
        let engine = makeEngine(blocking: ["reddit.com"], policy: policy)
        expectFailure(engine.temporarily("reddit.com", seconds: 599, start: 1800), .invalidDuration)
        expectFailure(engine.temporarily("reddit.com", seconds: 1201, start: 1800), .invalidDuration)
        expectFailure(engine.temporarily("reddit.com", seconds: 900, start: 3601), .invalidDuration)
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 3600))
        let other = makeEngine(blocking: ["reddit.com"], policy: policy)
        expectSuccess(other.temporarily("reddit.com", seconds: 1200, start: 1800))
    }
}
