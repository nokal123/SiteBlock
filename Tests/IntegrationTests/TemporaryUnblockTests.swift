import Foundation
import SiteBlockCore
import Testing

// Temporary unblocks against the real siteblockd running with --policy-fast (unblock delay 2 s, shortest window 1 s), through the real socket, the real hosts file and the
// real browser policy files in the sandbox. Design: 05-testing-and-operations.md § Integration Tests (the temporary unblock bullets); 01-overview-and-data.md § How Blocking Works
// ("Temporary unblock"), § Wire Protocol (Commands) and § Fixed Policy Values; 02-core-components.md § Engine; 03-daemon-cli-app.md § Daemon Runtime ("Temporary unblocks",
// "Temporary unblock log lines"), § SocketServer step 6 and § HostsEnforcer step 7. What the files must hold is built by `ExpectedHosts` and `designLists` from the design's tables.
//
// Timing: the stopwatch of each test starts BEFORE the approving request is sent, so a site seen open earlier than the start wait, or blocked again earlier than start wait plus window,
// would be a countdown that ran early (never allowed: 01 § Countdown, 03 § Daemon Runtime "Before every command").

private let password = SandboxDaemon.password

// The log lines that mean the daemon repaired something nobody asked it to change. A rewrite caused by a temporary unblock opening or ending is on purpose (03 § Daemon Runtime), so none of these may appear for it.
private let tamperLogLines = ["hosts file repaired", "blocks removed from hosts file", "Chrome policy repaired"] + BrowserUnderTest.allCases.map(\.repairedLine)

@Suite("Temporary unblock")
struct TemporaryUnblockTests {
    // MARK: the full cycle

    // 05 Integration Tests: "after approval the site's lines stay in the sandbox hosts file and its entries stay in the sandbox browser policy files for the whole start wait, they are gone
    // after the start wait, and they are back after the window ends." A start wait of 4 s and a window of 3 s. The other blocked site is untouched throughout, and the rewrites that open and
    // end the temporary unblock are not logged as tampering (03 § Daemon Runtime: "The block list changes on purpose in both cases").
    @Test func aSiteIsBlockedThroughTheStartWaitOpenForTheWindowAndBlockedAgain() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            try daemon.requireTwoSecondDelay()
            let bothBlocked = daemon.hostsExpected(blocking: ["reddit.com", "example.com"])
            let redditOpen = daemon.hostsExpected(blocking: ["example.com"])
            let bothLists = designLists(sites: ["reddit.com", "example.com"])
            let openLists = designLists(sites: ["example.com"])
            try require(daemon.hostsText() == bothBlocked, "the starting hosts file is wrong:\n\(daemon.hostsText())")
            try require(waitUntil(timeout: 1.5) { daemon.browserFilesHold(bothLists) } != nil, "the starting browser policy files are wrong")
            let tamperLines = tamperLogLines

            let watch = Stopwatch()
            let reply = try daemon.sendTemporary(domain: "reddit.com", seconds: 3, startSeconds: 4).requireOK()
            let countsAfterApproval = tamperLines.map { daemon.logCount(of: $0) }
            #expect(reply.message == "reddit.com opens in 4 seconds, for 3 seconds, then blocks again.")
            let approved = try #require(reply.status?.blocked.first { $0.domain == "reddit.com" }?.temporaryUnblock)
            #expect((3...4).contains(approved.opensInSeconds ?? -1) && approved.secondsRemaining == 3 && approved.windowSeconds == 3 && approved.isOpen == false, "got \(approved)")
            #expect(daemon.hostsText() == bothBlocked, "approval changes nothing yet: the site is blocked during the start wait")
            #expect(daemon.browserFilesHold(bothLists))

            // The whole start wait: the site's lines never leave. Sampled every 0.1 s until 3.5 s into the 4 s wait.
            var samples = 0
            while watch.elapsed < 3.5 {
                #expect(daemon.hostsText() == bothBlocked, "the site's lines left the hosts file \(watch.elapsed) s into a 4 s start wait")
                if samples % 5 == 0 { #expect(daemon.browserFilesHold(bothLists), "the browser policy files changed \(watch.elapsed) s into a 4 s start wait") }
                samples += 1
                pause(0.1)
            }
            let waiting = try daemon.temporaryStatus(ofSite: "reddit.com")
            #expect(waiting?.isOpen == false && (1...2).contains(waiting?.opensInSeconds ?? -1) && waiting?.secondsRemaining == 3, "got \(String(describing: waiting))")

            // It opens: the lines are gone, the other site's lines stay, and not before the start wait is over.
            let opened = waitUntil(timeout: 3.0) { daemon.hostsText() == redditOpen }
            let openedAt = watch.elapsed
            #expect(opened != nil, "the site's lines were still in the hosts file \(openedAt) s after a 4 s start wait began:\n\(daemon.hostsText())")
            #expect(openedAt >= 4.0, "the site opened after \(openedAt) s, before the 4 s start wait was over")
            #expect(openedAt < 4.7, "the site opened only \(openedAt) s after a 4 s start wait began; the daemon ticks every 0.2 s, so it should open within about one tick")
            #expect(waitUntil(timeout: 1.5) { daemon.browserFilesHold(openLists) } != nil, "the open site's entries must leave every browser policy file")
            let open = try daemon.temporaryStatus(ofSite: "reddit.com")
            #expect(open?.isOpen == true && open?.opensInSeconds == nil && (1...3).contains(open?.secondsRemaining ?? -1) && open?.windowSeconds == 3, "got \(String(describing: open))")
            #expect(try daemon.status().blocked.map(\.domain) == ["reddit.com", "example.com"], "the site stays on the list while it is open")

            // The window: the file stays as it is until the window is over.
            while watch.elapsed < 6.6 {
                #expect(daemon.hostsText() == redditOpen, "the site was blocked again \(watch.elapsed) s in, before the 3 s window was over")
                pause(0.1)
            }

            // It ends: the lines and entries are back, and not before start wait plus window.
            let ended = waitUntil(timeout: 3.0) { daemon.hostsText() == bothBlocked }
            let endedAt = watch.elapsed
            #expect(ended != nil, "the site was still open \(endedAt) s in:\n\(daemon.hostsText())")
            #expect(endedAt >= 7.0, "the site was blocked again after \(endedAt) s, before the 4 s start wait plus the 3 s window were over")
            #expect(endedAt < 7.7, "the site was blocked again only \(endedAt) s after the request; 4 s plus 3 s plus about one 0.2 s tick was expected")
            #expect(waitUntil(timeout: 1.5) { daemon.browserFilesHold(bothLists) } != nil, "the site's entries must return to every browser policy file")
            let after = try daemon.status()
            #expect(after.blocked.map(\.domain) == ["reddit.com", "example.com"] && after.blocked.allSatisfy { $0.temporaryUnblock == nil })
            let saved = try #require(daemon.stateObject())
            #expect((saved["blocked"] as? [[String: Any]])?.allSatisfy { $0["temporaryUnblock"] == nil } == true, "the finished temporary unblock is saved as gone")

            // The three log lines, once each, and no tamper repair for the two on-purpose rewrites.
            #expect(daemon.waitForLogCount(of: TemporaryLogLine.ended, atLeast: 1))
            pause(0.4)
            #expect(daemon.logCount(of: TemporaryLogLine.approved(opensIn: "4 seconds", window: "3 seconds")) == 1)
            #expect(daemon.logCount(of: TemporaryLogLine.opened) == 1)
            #expect(daemon.logCount(of: TemporaryLogLine.ended) == 1)
            #expect(tamperLines.map { daemon.logCount(of: $0) } == countsAfterApproval, "opening and ending a temporary unblock must not be logged as tampering: \(daemon.logText())")
        }
    }

    // 05 Integration Tests: "The same is checked for a path rule, whose entries are in the browser policy files only." The hosts file is the idle one throughout.
    @Test func aPathRuleIsInTheBrowserFilesThroughTheStartWaitLeavesThemForTheWindowAndComesBack() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.requireTwoSecondDelay()
            let withRule = designLists(sites: [], rules: [(domain: "youtube.com", path: "/shorts")])
            let withoutRule = designLists(sites: [], rules: [])
            try require(withRule.chrome == ["youtube.com/shorts"] && withRule.firefox == ["*://*.youtube.com/shorts*"], "the design's lists for one rule")
            try require(waitUntil(timeout: 1.5) { daemon.browserFilesHold(withRule) } != nil, "the starting browser policy files are wrong")

            let watch = Stopwatch()
            let reply = try daemon.sendTemporary(.temporaryUnblockPath, domain: "https://www.youtube.com/shorts/", seconds: 2, startSeconds: 3).requireOK()
            #expect(reply.message == "youtube.com/shorts opens in 3 seconds, for 2 seconds, then blocks again.")
            #expect(try daemon.temporaryStatus(ofRule: "youtube.com/shorts")?.isOpen == false)
            #expect(try daemon.status().blocked.isEmpty, "a rule's temporary unblock is not a site's")
            while watch.elapsed < 2.5 {
                #expect(daemon.browserFilesHold(withRule), "the rule left the browser policy files \(watch.elapsed) s into a 3 s start wait")
                #expect(daemon.hostsText() == ExpectedHosts.idleText)
                pause(0.15)
            }
            let opened = waitUntil(timeout: 2.5) { daemon.browserFilesHold(withoutRule) }
            #expect(opened != nil, "the rule's entries were still in the browser files \(watch.elapsed) s in")
            let ruleOpenedAt = watch.elapsed
            #expect(ruleOpenedAt >= 3.0, "the rule opened after \(ruleOpenedAt) s, before the 3 s start wait was over")
            #expect(ruleOpenedAt < 3.7, "the rule opened only \(ruleOpenedAt) s after a 3 s start wait began (one 0.2 s tick plus margin was expected)")
            #expect(try daemon.temporaryStatus(ofRule: "youtube.com/shorts")?.isOpen == true)
            #expect(daemon.hostsText() == ExpectedHosts.idleText, "a rule never touches the hosts file")
            let ended = waitUntil(timeout: 3.5) { daemon.browserFilesHold(withRule) }
            #expect(ended != nil, "the rule was still open \(watch.elapsed) s in")
            let ruleEndedAt = watch.elapsed
            #expect(ruleEndedAt >= 5.0, "the rule was blocked again after \(ruleEndedAt) s, before 3 s plus 2 s were over")
            #expect(ruleEndedAt < 5.7, "the rule was blocked again only \(ruleEndedAt) s after the request (3 s plus 2 s plus one tick and margin was expected)")
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
            #expect(try daemon.status().blockedPaths?.map(\.rule) == ["youtube.com/shorts"] && daemon.temporaryStatus(ofRule: "youtube.com/shorts") == nil)
            #expect(daemon.waitForLogCount(of: TemporaryLogLine.approved(opensIn: "3 seconds", window: "2 seconds"), atLeast: 1))
            #expect(daemon.waitForLogCount(of: TemporaryLogLine.opened, atLeast: 1))
            #expect(daemon.waitForLogCount(of: TemporaryLogLine.ended, atLeast: 1))
        }
    }

    // 02 § Engine, blockedHosts: "A host that another blocked site, one that is not open, also lists stays in." x.com and twitter.com share the related names, so with x.com open the sandbox
    // hosts file holds exactly twitter.com's names, shared ones included, and not the five that belong to x.com alone.
    @Test func aNameThatAnotherBlockedSiteAlsoListsStaysInTheHostsFileWhileOneSiteIsOpen() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "x.com", "twitter.com")
            try daemon.requireTwoSecondDelay()
            let both = daemon.hostsExpected(blocking: ["x.com", "twitter.com"])
            let twitterOnly = daemon.hostsExpected(blocking: ["twitter.com"])
            try require(both != twitterOnly, "the two sites must differ in at least one name")
            let watch = Stopwatch()
            try daemon.sendTemporary(domain: "x.com", seconds: 3, startSeconds: 2).requireOK()
            #expect(daemon.hostsText() == both)
            #expect(waitUntil(timeout: 3.5) { daemon.hostsText() == twitterOnly } != nil, "x.com did not open; file:\n\(daemon.hostsText())")
            #expect(watch.elapsed >= 2.0 && watch.elapsed < 2.7, "x.com opened \(watch.elapsed) s after a 2 s start wait began")
            let view = daemon.hosts()
            for name in ["x.com", "twitter.com", "api.twitter.com", "pbs.twimg.com", "www.x.com"] { #expect(view.blocks(name), "\(name) is shared with twitter.com, so it must stay blocked") }
            for name in ["old.x.com", "new.x.com", "amp.x.com", "app.x.com", "web.x.com"] { #expect(!view.blocks(name), "\(name) belongs to x.com alone, which is open") }
            #expect(waitUntil(timeout: 1.5) { daemon.browserFilesHold(designLists(sites: ["twitter.com"])) } != nil)
            #expect(waitUntil(timeout: 4.5) { daemon.hostsText() == both } != nil, "x.com was not blocked again; file:\n\(daemon.hostsText())")
            #expect(watch.elapsed >= 5.0 && watch.elapsed < 5.7, "x.com was blocked again \(watch.elapsed) s after the request (2 s plus 3 s plus a tick was expected)")
        }
    }

    // 01 § How Blocking Works: "a path rule on a site whose whole site is open stays in them [the browsers' lists], because that rule is what keeps that part of the site blocked."
    @Test func aPathRuleOnAnOpenSiteStaysInTheBrowserFilesWhileTheSiteLeavesTheHostsFile() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.block("youtube.com")
            try daemon.requireTwoSecondDelay()
            let blocked = daemon.hostsExpected(blocking: ["youtube.com"])
            let cover = designLists(sites: ["youtube.com"], rules: [(domain: "youtube.com", path: "/shorts")])
            let ruleOnly = designLists(sites: [], rules: [(domain: "youtube.com", path: "/shorts")])
            try require(ruleOnly.chrome == ["youtube.com/shorts"] && cover.chrome.contains("youtube.com") && !cover.chrome.contains("youtube.com/shorts"), "the design's lists")
            try require(daemon.hostsText() == blocked, "the starting hosts file is wrong")
            try require(waitUntil(timeout: 1.5) { daemon.browserFilesHold(cover) } != nil, "the starting browser policy files are wrong")
            try daemon.sendTemporary(domain: "youtube.com", seconds: 3, startSeconds: 2).requireOK()
            #expect(waitUntil(timeout: 3.5) { daemon.hostsText() == ExpectedHosts.idleText } != nil, "the open site's names must leave the hosts file; file:\n\(daemon.hostsText())")
            #expect(waitUntil(timeout: 1.5) { daemon.browserFilesHold(ruleOnly) } != nil, "while the whole site is open the rule is the only entry left")
            #expect(waitUntil(timeout: 4.5) { daemon.hostsText() == blocked && daemon.browserFilesHold(cover) } != nil, "the site must be blocked again, in the hosts file and in the browsers' lists")
        }
    }

    // MARK: cancelling and ending early

    // 05 Integration Tests: "Cancelling a waiting temporary unblock and ending an open one early put the site's lines and entries back before the response returns, with no password."
    // The daemon ticks only every 60 s, so no timer can explain a file that is right when the reply arrives. A waiting one never left, so only the reply and the state are new.
    @Test func cancellingAWaitingTemporaryUnblockKeepsEverythingBlockedWithNoPassword() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = daemon.hostsExpected(blocking: ["reddit.com"])
            let lists = designLists(sites: ["reddit.com"])
            try daemon.sendTemporary(domain: "reddit.com", seconds: 300, startSeconds: 600).requireOK()
            #expect(daemon.hostsText() == blocked && daemon.browserFilesHold(lists))
            let reply = try daemon.send(.cancelUnblock, domain: "reddit.com").requireOK()
            #expect(reply.message == "The temporary unblock is cancelled; reddit.com stays blocked.")
            #expect(reply.status?.blocked.first?.temporaryUnblock == nil)
            #expect(daemon.hostsText() == blocked && daemon.browserFilesHold(lists))
            #expect(try daemon.status().blocked.map(\.domain) == ["reddit.com"])
            #expect(daemon.logCount(of: TemporaryLogLine.cancelled) == 1)
            let again = try daemon.send(.cancelUnblock, domain: "reddit.com")
            #expect(again.ok == false && again.errorCode == .nothingPending, "nothing is left to cancel")
        }
    }

    // How a test ends an open temporary unblock.
    enum EndMethod: CaseIterable, CustomTestStringConvertible {
        case cancelUnblock, addAgain, cancelUnblockPath, addPathAgain
        var testDescription: String {
            switch self {
            case .cancelUnblock: return "Block now (cancelUnblock)"
            case .addAgain: return "adding the site again"
            case .cancelUnblockPath: return "Block now for a rule (cancelUnblockPath)"
            case .addPathAgain: return "adding the rule again"
            }
        }
        var isRule: Bool { self == .cancelUnblockPath || self == .addPathAgain }
    }

    // The open site (or rule) is ended early. The daemon ticks only every 60 s: the temporary unblock opens in the catch-up before the next command (03 § Daemon Runtime, "Before every
    // command"), and the files are right when THAT reply arrives; then the ending command puts the lines and entries back before ITS reply arrives, with no password.
    @Test(arguments: EndMethod.allCases)
    func endingAnOpenTemporaryUnblockEarlyBlocksAgainBeforeTheReplyReturns(method: EndMethod) throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.setUp()
            try daemon.block("example.com")
            if method.isRule { try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK() } else { try daemon.block("reddit.com") }
            try daemon.requireTwoSecondDelay()
            let sites = method.isRule ? ["example.com"] : ["reddit.com", "example.com"]
            let rules = method.isRule ? [(domain: "youtube.com", path: "/shorts")] : []
            let allBlocked = daemon.hostsExpected(blocking: sites)
            let allLists = designLists(sites: sites, rules: rules)
            let openHosts = daemon.hostsExpected(blocking: ["example.com"])
            let openLists = designLists(sites: ["example.com"], rules: [])
            let target = method.isRule ? "youtube.com/shorts" : "reddit.com"
            try daemon.sendTemporary(method.isRule ? .temporaryUnblockPath : .temporaryUnblock, domain: target, seconds: 3600, startSeconds: 2).requireOK()
            try require(daemon.hostsText() == allBlocked, "approval must not open anything yet")
            let tamperCounts = tamperLogLines.map { daemon.logCount(of: $0) }
            pause(2.5)
            // A harmless command: the catch-up before it opens the temporary unblock and the enforcement pass after it writes the files.
            try daemon.send(.add, domain: "example.com").requireNotOK(.alreadyBlocked)
            try require(daemon.hostsText() == openHosts, "the catch-up before a command must open it and enforce at once; file:\n\(daemon.hostsText())")
            try require(daemon.browserFilesHold(openLists), "the browser files must be written in that same pass")
            #expect(tamperLogLines.map { daemon.logCount(of: $0) } == tamperCounts, "the catch-up opened the temporary unblock on purpose; the rewrite must not be logged as tampering: \(daemon.logText())")
            let openNow = method.isRule ? try daemon.temporaryStatus(ofRule: target) : try daemon.temporaryStatus(ofSite: target)
            try require(openNow?.isOpen == true, "the temporary unblock should be open before it is ended; got \(String(describing: openNow))")
            let end: Response
            switch method {
            case .cancelUnblock: end = try daemon.send(.cancelUnblock, domain: target)
            case .addAgain: end = try daemon.send(.add, domain: target)
            case .cancelUnblockPath: end = try daemon.send(.cancelUnblockPath, domain: target)
            case .addPathAgain: end = try daemon.send(.addPath, domain: target)
            }
            try end.requireOK()
            #expect(end.message == "\(target) is blocked again.")
            #expect(daemon.hostsText() == allBlocked, "the lines must be back when the reply arrives; file:\n\(daemon.hostsText())")
            #expect(daemon.browserFilesHold(allLists), "the entries must be back when the reply arrives")
            #expect(try daemon.status().blocked.allSatisfy { $0.temporaryUnblock == nil } && daemon.status().blockedPaths?.allSatisfy { $0.temporaryUnblock == nil } == true)
            #expect(daemon.logCount(of: TemporaryLogLine.opened) == 1, "opened is logged once, by the catch-up before the first command")
            #expect(daemon.logCount(of: TemporaryLogLine.endedEarly) == 1)
            #expect(tamperLogLines.map { daemon.logCount(of: $0) } == tamperCounts, "ending it early on purpose must not be logged as tampering either: \(daemon.logText())")
        }
    }

    // 03 § Daemon Runtime: a temporary unblock ends inside the catch-up before a command just as it opens there. When the gap covers the whole start wait and the window ("a gap that covers both
    // reports only the ending", 02 § Engine), the files are back when the reply arrives and the log has the ending and no opening.
    @Test func aGapThatCoversTheWholeStartWaitAndWindowFinishesInTheCatchUpAndLogsOnlyTheEnding() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            try daemon.requireTwoSecondDelay()
            let blocked = daemon.hostsExpected(blocking: ["reddit.com", "example.com"])
            let lists = designLists(sites: ["reddit.com", "example.com"])
            let watch = Stopwatch()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 1, startSeconds: 2).requireOK()
            let tamperCounts = tamperLogLines.map { daemon.logCount(of: $0) }
            pause(3.5 - watch.elapsed)
            try daemon.send(.add, domain: "reddit.com").requireNotOK(.alreadyBlocked)
            #expect(tamperLogLines.map { daemon.logCount(of: $0) } == tamperCounts, "a temporary unblock that finished in the catch-up changed nothing but on purpose: \(daemon.logText())")
            #expect(daemon.hostsText() == blocked, "finished inside the catch-up: the lines are back when the reply arrives")
            #expect(daemon.browserFilesHold(lists))
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com") == nil)
            #expect(daemon.waitForLogCount(of: TemporaryLogLine.ended, atLeast: 1))
            #expect(daemon.logCount(of: TemporaryLogLine.ended) == 1)
            #expect(daemon.logCount(of: TemporaryLogLine.opened) == 0, "a gap that covers both reports only the ending")
            _ = try daemon.send(.add, domain: "reddit.com")
            _ = try daemon.send(.add, domain: "example.com")
            #expect(daemon.logCount(of: TemporaryLogLine.ended) == 1, "an ending is logged once, however many commands follow")
        }
    }

    // The opening is logged once even though many later commands run the catch-up again.
    @Test func anOpeningInTheCatchUpIsLoggedOnceNotOnEveryLaterCommand() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 3600, startSeconds: 2).requireOK()
            pause(2.4)
            for _ in 0..<4 { _ = try daemon.send(.cancelDelayChange) }
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com")?.isOpen == true)
            #expect(daemon.logCount(of: TemporaryLogLine.opened) == 1)
            #expect(daemon.logCount(of: TemporaryLogLine.approved(opensIn: "2 seconds", window: "1 hour")) == 1)
        }
    }

    // MARK: refusals

    // 01 § Commands (temporaryUnblock): all the checks before the password "come before the password check, so a request that fails one of them never counts as a wrong password."
    // Every refusal below is sent through the real socket with a WRONG password: none counts, so five of them do not lock the daemon out, while five valid requests with a wrong password do.
    @Test func refusedRequestsNeverCountAsWrongPasswordsButValidOnesDo() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "pending.example", "temp.example")
            try daemon.requireTwoSecondDelay()
            // A longer delay applies at once; 600 s keeps the waiting permanent unblock below from finishing while the test runs.
            try daemon.send(.setDelay, password: password, seconds: 600).requireOK()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.send(.unblock, domain: "pending.example", password: password).requireOK()
            try daemon.sendTemporary(domain: "temp.example", seconds: 3600, startSeconds: 3600).requireOK()
            let wrong = "not-the-password"
            let refusals: [(name: String, request: Request, code: ErrorCode)] = [
                ("missing window", Request(command: .temporaryUnblock, domain: "reddit.com", password: wrong), .badRequest),
                ("missing password", Request(command: .temporaryUnblock, domain: "reddit.com", seconds: 300), .badRequest),
                ("missing site", Request(command: .temporaryUnblock, password: wrong, seconds: 300), .badRequest),
                ("bad site name", Request(command: .temporaryUnblock, domain: "1.2.3.4", password: wrong, seconds: 300), .invalidDomain),
                ("unknown site", Request(command: .temporaryUnblock, domain: "nowhere.example", password: wrong, seconds: 300), .notBlocked),
                ("waiting permanent unblock", Request(command: .temporaryUnblock, domain: "pending.example", password: wrong, seconds: 300), .alreadyPending),
                ("waiting temporary unblock", Request(command: .temporaryUnblock, domain: "temp.example", password: wrong, seconds: 300), .alreadyPending),
                ("window below the minimum", Request(command: .temporaryUnblock, domain: "reddit.com", password: wrong, seconds: 0), .invalidDuration),
                ("window above four hours", Request(command: .temporaryUnblock, domain: "reddit.com", password: wrong, seconds: 14_401), .invalidDuration),
                ("start wait below the delay (600 s)", Request(command: .temporaryUnblock, domain: "reddit.com", password: wrong, seconds: 300, startSeconds: 599), .invalidDuration),
                ("start wait above seven days", Request(command: .temporaryUnblock, domain: "reddit.com", password: wrong, seconds: 300, startSeconds: 604_801), .invalidDuration),
                ("rule without a path", Request(command: .temporaryUnblockPath, domain: "youtube.com", password: wrong, seconds: 300), .invalidPath),
                ("unknown rule", Request(command: .temporaryUnblockPath, domain: "youtube.com/watch", password: wrong, seconds: 300), .notBlocked),
                ("permanent unblock of a site with a temporary one", Request(command: .unblock, domain: "temp.example", password: wrong), .alreadyPending),
            ]
            for round in 0..<2 {
                for refusal in refusals {
                    let reply = try daemon.client().send(refusal.request)
                    #expect(reply.ok == false && reply.errorCode == refusal.code, "round \(round), \(refusal.name): got \(String(describing: reply.errorCode)): \(reply.error ?? "")")
                    #expect(reply.errorCode != .wrongPassword && reply.errorCode != .lockedOut, "\(refusal.name) reached the password check")
                }
            }
            #expect(try daemon.status().lockoutSecondsRemaining == nil, "28 refused requests must not start a lockout")
            #expect(daemon.stateObject()?["failedAttempts"] as? Int == 0, "and must not count a single wrong password")
            let window = try daemon.send(.temporaryUnblock, domain: "reddit.com", password: wrong, seconds: 300)
            #expect(window.errorCode == .wrongPassword, "a VALID request with the wrong password does count")
            #expect(daemon.stateObject()?["failedAttempts"] as? Int == 1)
            // The password-protected state stays as it was: the refusals changed nothing about the two earlier unblocks.
            #expect(try daemon.temporaryStatus(ofSite: "temp.example")?.windowSeconds == 3600)
            #expect(try daemon.status().blocked.first { $0.domain == "pending.example" }?.unblockSecondsRemaining != nil, "the waiting permanent unblock was not touched")
        }
    }

    // Five valid requests with a wrong password lock the daemon out, and the lockout holds for a right password too (the password rule), while a request that fails an earlier check is still answered by that check.
    @Test func fiveValidRequestsWithAWrongPasswordLockOutAndAnEarlierRefusalIsStillAnsweredByItsOwnCheck() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            for _ in 0..<5 { #expect(try daemon.send(.temporaryUnblock, domain: "reddit.com", password: "not-the-password", seconds: 300).errorCode == .wrongPassword) }
            #expect(try daemon.status().lockoutSecondsRemaining != nil, "five wrong passwords start the lockout")
            let valid = try daemon.sendTemporary(domain: "reddit.com", seconds: 300)
            #expect(valid.errorCode == .lockedOut, "even the right password is refused during the lockout")
            #expect(try daemon.sendTemporary(domain: "reddit.com", seconds: 0).errorCode == .invalidDuration, "a refusal before the password check is answered by that check, lockout or not")
            #expect(try daemon.sendTemporary(domain: "nowhere.example", seconds: 300).errorCode == .notBlocked)
        }
    }

    // Pins the order badRequest before invalidDomain/invalidPath, which is what the handler's skip of the name check for an incomplete request produces (03 § SocketServer step 6 and 02 § Engine, Argument rule). The replies are the same whether the name check runs on the connection thread or in the engine, so only the order is visible from outside.
    // 03 § SocketServer step 6: for temporaryUnblock the handler checks the site name on the connection's own thread and answers invalidDomain at once, and for temporaryUnblockPath the rule text
    // (invalidDomain or invalidPath). "A request that is also missing a required argument (the password for an unblock; the password or the window for a temporary unblock) skips this check,
    // so the engine answers badRequest first."
    @Test func aMissingPasswordOrWindowIsBadRequestBeforeABadNameIsInvalidDomain() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            // Sends one raw request line with exactly the fields given and returns the error code of the reply.
            func code(_ command: String, domain: String? = nil, password: String? = nil, seconds: Any? = nil, start: Any? = nil) throws -> String? {
                var fields: [String: Any] = ["command": command]
                if let domain { fields["domain"] = domain }
                if let password { fields["password"] = password }
                if let seconds { fields["seconds"] = seconds }
                if let start { fields["startSeconds"] = start }
                return try rawExchange(try requestLine(fields), socketPath: daemon.socketPath).errorCode
            }
            #expect(try code("temporaryUnblock", domain: "1.2.3.4", password: password, seconds: 300) == "invalidDomain")
            #expect(try code("temporaryUnblock", domain: "1.2.3.4", seconds: 300) == "badRequest", "missing password: the engine answers badRequest first")
            #expect(try code("temporaryUnblock", domain: "1.2.3.4", password: password) == "badRequest", "missing window: the engine answers badRequest first")
            #expect(try code("temporaryUnblock", password: password, seconds: 300) == "badRequest", "missing site")
            #expect(try code("temporaryUnblockPath", domain: "reddit.com", password: password, seconds: 300) == "invalidPath", "a rule text without a path")
            #expect(try code("temporaryUnblockPath", domain: "1.2.3.4/x", password: password, seconds: 300) == "invalidDomain")
            #expect(try code("temporaryUnblockPath", domain: "reddit.com", seconds: 300) == "badRequest")
            #expect(try code("temporaryUnblockPath", domain: "reddit.com", password: password) == "badRequest")
            #expect(try code("temporaryUnblock", domain: "reddit.com", password: password, seconds: "soon") == "badRequest", "a window that is not a number is a malformed request")
            #expect(try code("temporaryUnblock", domain: "reddit.com", password: password, seconds: 300, start: 1.5) == "badRequest", "a start wait that is not a whole number is a malformed request")
            #expect(try code("temporaryUnblock", domain: "reddit.com", password: password, seconds: 300, start: "1h") == "badRequest")
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com") == nil, "nothing above scheduled anything")
        }
    }

    // MARK: the log

    // 03 § Daemon Runtime: five log lines (approved, opened, ended, cancelled while waiting, ended early); "No line names the site or rule", and passwords are never logged. One daemon, four
    // temporary unblocks (three sites and a rule), each ending a different way. Every line is counted: a repeated or missing line is a bug.
    @Test func theLogHoldsTheFiveLinesTheDesignListsAndNeverASiteRuleOrPassword() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "bluebird-two.net", "bluebird-three.org")
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.requireTwoSecondDelay()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 2, startSeconds: 2).requireOK()
            try daemon.sendTemporary(domain: "bluebird-two.net", seconds: 300, startSeconds: 600).requireOK()
            try daemon.sendTemporary(domain: "bluebird-three.org", seconds: 600, startSeconds: 2).requireOK()
            try daemon.sendTemporary(.temporaryUnblockPath, domain: "youtube.com/shorts", seconds: 2, startSeconds: 2).requireOK()
            try daemon.send(.cancelUnblock, domain: "bluebird-two.net").requireOK()
            try require(waitUntil(timeout: 5) { !daemon.hosts().blocks("bluebird-three.org") } != nil, "bluebird-three.org never opened")
            let early = try daemon.send(.cancelUnblock, domain: "bluebird-three.org").requireOK()
            #expect(early.message == "bluebird-three.org is blocked again.")
            #expect(daemon.waitForLogCount(of: TemporaryLogLine.ended, atLeast: 2, within: 6), "the two short ones must end by themselves:\n\(daemon.logText())")
            pause(0.5)
            #expect(daemon.logCount(of: TemporaryLogLine.approved(opensIn: "2 seconds", window: "2 seconds")) == 2)
            #expect(daemon.logCount(of: TemporaryLogLine.approved(opensIn: "10 minutes", window: "5 minutes")) == 1)
            #expect(daemon.logCount(of: TemporaryLogLine.approved(opensIn: "2 seconds", window: "10 minutes")) == 1)
            #expect(daemon.logCount(of: "temporary unblock approved") == 4)
            #expect(daemon.logCount(of: TemporaryLogLine.opened) == 3, "reddit.com, bluebird-three.org and the rule each opened once")
            #expect(daemon.logCount(of: TemporaryLogLine.ended) == 2, "reddit.com and the rule ended by themselves")
            #expect(daemon.logCount(of: TemporaryLogLine.cancelled) == 1)
            #expect(daemon.logCount(of: TemporaryLogLine.endedEarly) == 1)
            let lines = daemon.logText().components(separatedBy: "\n").filter { $0.contains("temporary unblock") }
            for line in lines {
                let known = [TemporaryLogLine.opened, TemporaryLogLine.ended, TemporaryLogLine.cancelled, TemporaryLogLine.endedEarly]
                #expect(known.contains { line.hasSuffix($0) } || line.contains("temporary unblock approved: opens in "), "an unexpected temporary unblock line: \(line)")
            }
            let log = daemon.logText().lowercased()
            for name in ["reddit", "bluebird", "youtube", "shorts", password.lowercased()] { #expect(!log.contains(name), "\(name) appears in the log:\n\(log)") }
        }
    }

    // 03 § Daemon Runtime, Logging: "Successful commands other than `status` are logged by name and user ID, and so is every password check, right or wrong. Other rejected commands ... are counted
    // per user ID and logged as one summary line per minute". So a valid temporary unblock request with a wrong password is logged (it compared a password), a right one is logged, and requests
    // refused before the password check leave no line of their own.
    @Test func everyPasswordCheckOfATemporaryUnblockRequestIsLoggedByNameAndUserIdAndEarlierRefusalsAreNot() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            func namedLines() -> [String] { daemon.logText().components(separatedBy: "\n").filter { $0.contains("temporaryUnblock") } }
            #expect(namedLines().isEmpty)
            _ = try daemon.sendTemporary(domain: "reddit.com", password: "not-the-password", seconds: 300)
            #expect(waitUntil(timeout: 1.5) { namedLines().count == 1 } != nil, "a wrong password in a valid request is a password check and must be logged: \(daemon.logText())")
            #expect(namedLines().first?.contains(String(getuid())) == true, "the line carries the caller's user ID: \(namedLines())")
            for _ in 0..<5 { _ = try daemon.sendTemporary(domain: "reddit.com", password: "not-the-password", seconds: 0) }
            for _ in 0..<5 { _ = try daemon.sendTemporary(domain: "nowhere.example", password: "not-the-password", seconds: 300) }
            pause(0.4)
            #expect(namedLines().count == 1, "ten requests refused before the password check must not be logged one by one: \(namedLines())")
            try daemon.sendTemporary(domain: "reddit.com", seconds: 300, startSeconds: 600).requireOK()
            #expect(waitUntil(timeout: 1.5) { namedLines().count == 2 } != nil, "a successful temporary unblock is logged by name and user ID: \(daemon.logText())")
            #expect(namedLines().last?.contains(String(getuid())) == true)
        }
    }

    // 05 § Integration Tests: "Passwords, domains and path rules never appear in the daemon log, including the temporary unblock lines." Every command that takes a rule text is sent (valid, refused
    // for its path, refused for its host, wrong password, right password), and no part of the rule or its site appears in the log afterwards.
    @Test func pathRulesAreNeverLoggedByAnyCommand() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.requireTwoSecondDelay()
            try daemon.send(.addPath, domain: "https://www.secretvideo.example/hidden-part-xq/abc").requireOK()
            _ = try daemon.send(.addPath, domain: "secretvideo.example/hidden-part-xq")
            _ = try daemon.send(.addPath, domain: "secretvideo.example/bad path-xq")
            _ = try daemon.send(.addPath, domain: "1.2.3.4/leaky-path-xq")
            _ = try daemon.send(.unblockPath, domain: "secretvideo.example/hidden-part-xq/abc", password: "not-the-password")
            try daemon.send(.unblockPath, domain: "secretvideo.example/hidden-part-xq/abc", password: password).requireOK()
            try daemon.send(.cancelUnblockPath, domain: "secretvideo.example/hidden-part-xq/abc").requireOK()
            _ = try daemon.sendTemporary(.temporaryUnblockPath, domain: "secretvideo.example/hidden-part-xq/abc", password: "not-the-password", seconds: 300)
            _ = try daemon.sendTemporary(.temporaryUnblockPath, domain: "secretvideo.example/hidden-part-xq/abc", seconds: 0)
            try daemon.sendTemporary(.temporaryUnblockPath, domain: "secretvideo.example/hidden-part-xq/abc", seconds: 300, startSeconds: 600).requireOK()
            try daemon.send(.cancelUnblockPath, domain: "secretvideo.example/hidden-part-xq/abc").requireOK()
            try daemon.sendTemporary(.temporaryUnblockPath, domain: "secretvideo.example/hidden-part-xq/abc", seconds: 1, startSeconds: 2).requireOK()
            #expect(daemon.waitForLogCount(of: TemporaryLogLine.ended, atLeast: 1, within: 6))
            pause(0.4)
            let log = daemon.logText().lowercased()
            for name in ["secretvideo", "hidden-part", "leaky-path", "bad path", "xq"] { #expect(!log.contains(name), "\(name) appears in the log:\n\(log)") }
        }
    }

    // MARK: saving while it runs

    // 01 § Fixed Policy Values: "A temporary unblock counts as a running countdown from the moment it is scheduled until it ends", so the state is saved at least every `saveIntervalSeconds` (15 in production,
    // 2 under --policy-fast, which this daemon runs with) while one waits or is open, with no other countdown running. The saved remaining time must therefore fall without any command being sent. Seven seconds
    // in, the last save is at most about 2.2 s old (the 2 s interval plus one 0.2 s tick), so it was written at least 4.6 s after the approval: a waiting one holds at most about 3595.4, and an open one (whose window
    // opened at about 2.0-2.4 s) at most about 3597.6. The ceilings below add slack for a slow machine. A daemon that kept the production 15 s would still show the approval-time value (about 3600) here.
    @Test(arguments: ["waiting", "open"], [false, true])
    func theStateIsSavedEverySaveIntervalWhileATemporaryUnblockWaitsOrIsOpen(phase: String, rule: Bool) throws {
        try withDaemon { daemon in
            if rule {
                try daemon.setUp()
                try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            } else {
                try daemon.prepare(blocking: "reddit.com")
            }
            try daemon.requireTwoSecondDelay()
            let start = phase == "waiting" ? 3600 : 2
            let watch = Stopwatch()
            try daemon.sendTemporary(rule ? .temporaryUnblockPath : .temporaryUnblock, domain: rule ? "youtube.com/shorts" : "reddit.com", seconds: 3600, startSeconds: start).requireOK()
            let list = rule ? "blockedPaths" : "blocked"
            let path: [Any] = phase == "waiting" ? [list, 0, "temporaryUnblock", "startsIn", "remainingSeconds"] : [list, 0, "temporaryUnblock", "window", "remainingSeconds"]
            pause(3.0 - watch.elapsed)
            let early = try #require(daemon.stateNumber(path), "the saved state has no temporary unblock yet")
            #expect(early > 3590, "a few seconds in, the saved file still holds (almost) the full time: \(early)")
            pause(7.0 - watch.elapsed)
            let later = try #require(daemon.stateNumber(path))
            // Waiting: the countdown started at the approval, so a save made at or after the 4.6 s mark holds at most 3595.4; the ceiling 3597 allows about 1.6 s of scheduling delay.
            // Open: the window opened at about 2.0-2.4 s, so the same save holds at most 3597.6; the ceiling 3599 allows the same kind of delay.
            let ceiling = phase == "waiting" ? 3597.0 : 3599.0
            #expect(later <= ceiling && later > 3592, "with nothing else running, the periodic save must have written the lower remaining time (at most \(ceiling), above 3592); saved \(later), 3 s in it was \(early)")
            if phase == "open" {
                let status = rule ? try daemon.temporaryStatus(ofRule: "youtube.com/shorts") : try daemon.temporaryStatus(ofSite: "reddit.com")
                #expect(status?.isOpen == true)
            }
        }
    }

    // MARK: tampering while a temporary unblock runs

    // While a site is open, someone deletes the managed section by hand. The daemon writes back what the block list asks for NOW, which does not include the open site: the tampering is undone
    // (and logged as a repair) without cancelling the temporary unblock.
    @Test func deletingTheManagedSectionWhileASiteIsOpenRestoresTheSectionWithoutTheOpenSite() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            try daemon.requireTwoSecondDelay()
            let open = daemon.hostsExpected(blocking: ["example.com"])
            try daemon.sendTemporary(domain: "reddit.com", seconds: 3600, startSeconds: 2).requireOK()
            try require(waitUntil(timeout: 4) { daemon.hostsText() == open } != nil, "the site never opened:\n\(daemon.hostsText())")
            let repairs = daemon.logCount(of: "hosts file repaired")
            try writeText(StandardHosts.text, to: daemon.hostsPath)
            #expect(waitUntil(timeout: 2.0) { daemon.hostsText() == open } != nil, "the managed section must come back, without the open site; file:\n\(daemon.hostsText())")
            #expect(daemon.waitForLogCount(of: "hosts file repaired", atLeast: repairs + 1), "hand tampering is logged even while a temporary unblock is open")
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com")?.isOpen == true, "the repair does not end the temporary unblock")
            // A hand-added line that points the OPEN site at a real address is not a bypass of a block: the name is not blocked right now, so the line stays.
            let hacked = open.replacingOccurrences(of: "127.0.0.1\tlocalhost\n", with: "127.0.0.1\tlocalhost\n151.101.1.140 reddit.com\n")
            try writeText(hacked, to: daemon.hostsPath)
            pause(1.0)
            #expect(daemon.hostsText() == hacked, "reddit.com is not blocked while it is open, so a user's own line for it is left alone")
            // Once the site is blocked again, the line is removed as a bypass.
            try daemon.send(.cancelUnblock, domain: "reddit.com").requireOK()
            #expect(daemon.hostsText() == daemon.hostsExpected(blocking: ["reddit.com", "example.com"]), "the bypass line goes when the block is back; file:\n\(daemon.hostsText())")
        }
    }
}

extension Response {
    // Throws a TestFailure unless the response is a failure with the given code. Used where a command is sent only for its side effect (the catch-up before it) and is expected to be refused.
    @discardableResult
    func requireNotOK(_ code: ErrorCode) throws -> Response {
        try require(!ok && errorCode == code, "expected \(code.rawValue), got ok=\(ok) \(errorCode?.rawValue ?? "?"): \(error ?? "")")
        return self
    }
}
