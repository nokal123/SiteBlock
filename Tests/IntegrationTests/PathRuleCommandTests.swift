import Foundation
import SiteBlockCore
import Testing

// The path rule commands (addPath, unblockPath, cancelUnblockPath) sent to the real siteblockd over its real socket.
// Design: 01-overview-and-data.md § Commands (addPath, unblockPath, cancelUnblockPath), § Response (error codes), § StatusSnapshot (blockedPaths),
// § Fixed Policy Values (the cap counts sites plus path rules); 02-core-components.md § Engine ("Path rules"); 03-daemon-cli-app.md § Daemon Runtime
// ("After every command: save the state, then enforce").

private let password = SandboxDaemon.password

// Sends a path command as raw JSON and returns the raw reply.
private func rawSend(_ command: String, domain: String? = nil, password: String? = nil, to daemon: SandboxDaemon) throws -> RawReply {
    var fields: [String: Any] = ["command": command]
    if let domain { fields["domain"] = domain }
    if let password { fields["password"] = password }
    return try rawExchange(try requestLine(fields), socketPath: daemon.socketPath)
}

@Suite("Path rule commands")
struct PathRuleCommandTests {
    // MARK: addPath

    // The reply to addPath carries the confirmation sentence and a status with the rule; the saved state holds it under blockedPaths before the reply is sent.
    @Test func addPathAnswersWithTheRuleInTheStatusAndSavesItBeforeReplying() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.setUp()
            let reply = try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            #expect(reply.message == "youtube.com/shorts is now blocked.")
            let rules = try #require(reply.status?.blockedPaths)
            #expect(rules == [BlockedPathStatus(domain: "youtube.com", path: "/shorts", rule: "youtube.com/shorts", unblockSecondsRemaining: nil)])
            #expect(reply.status?.blocked.isEmpty == true)
            let saved = try #require(daemon.stateObject())
            let savedRules = try #require(saved["blockedPaths"] as? [[String: Any]], "the state file must hold blockedPaths")
            #expect(savedRules.count == 1 && savedRules[0]["domain"] as? String == "youtube.com" && savedRules[0]["path"] as? String == "/shorts")
        }
    }

    // 02 § Engine, addPath: invalidDomain for host errors, invalidPath for path errors and for text with no path. Nothing is written for a refused request.
    @Test(arguments: [
        ("youtube.com", "invalidPath"),
        ("youtube.com/", "invalidPath"),
        ("https://www.youtube.com", "invalidPath"),
        ("youtube.com/*", "invalidPath"),
        ("youtube.com/my shorts", "invalidPath"),
        ("youtube.com/sho*rts", "invalidPath"),
        ("youtube.com/ü", "invalidPath"),
        ("youtube.com/a\"b", "invalidPath"),
        ("youtube.com/a<b>", "invalidPath"),
        ("youtube.com/a\\b", "invalidPath"),
        ("youtube.com/a|b", "invalidPath"),
        ("youtube.com/a\u{0}b", "invalidPath"),
        ("youtube.com/" + String(repeating: "a", count: 300), "invalidPath"),
        ("1.2.3.4/shorts", "invalidDomain"),
        ("localhost/x", "invalidDomain"),
        ("evil/x", "invalidDomain"),
        ("", "invalidDomain"),
        ("   ", "invalidDomain"),
        ("/shorts", "invalidDomain"),
        ("my_site.com/x", "invalidDomain"),
    ])
    func aRuleTextTheParserRefusesIsAnsweredWithTheDesignsCodeAndChangesNothing(text: String, code: String) throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let files = try daemon.browserFiles()
            let hostsBefore = daemon.hostsText()
            let reply = try rawSend("addPath", domain: text, to: daemon)
            #expect(reply.ok == false && reply.errorCode == code, "got \(reply.text.prefix(300))")
            pause(0.4)
            #expect(daemon.hostsText() == hostsBefore)
            #expect(try daemon.status().blockedPaths == [])
            for ref in files.refs {
                let path = try #require(files.path(ref))
                #expect(fileIsRight(path, ref.browser.expected(list: [])), "\(ref.testDescription) changed after a refused rule: \(String(describing: readPlist(path)))")
            }
            let saved = try #require(daemon.stateObject())
            #expect((saved["blockedPaths"] as? [Any] ?? []).isEmpty)
        }
    }

    // A request without a domain is a badRequest, for all three path commands.
    @Test(arguments: ["addPath", "unblockPath", "cancelUnblockPath"])
    func aPathCommandWithoutATextIsABadRequest(command: String) throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let reply = try rawSend(command, password: command == "unblockPath" ? password : nil, to: daemon)
            #expect(reply.ok == false && reply.errorCode == "badRequest", "got \(reply.text.prefix(300))")
        }
    }

    // 01 § Commands: addPath "Fails ... notSetUp when no password exists".
    @Test func beforeAPasswordExistsAddPathIsNotSetUp() throws {
        try withDaemon { daemon in
            let reply = try daemon.send(.addPath, domain: "youtube.com/shorts")
            #expect(reply.ok == false && reply.errorCode == .notSetUp)
        }
    }

    @Test func theSameRuleTwiceAndARuleOnAWholeBlockedSiteAreBothAlreadyBlocked() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let again = try daemon.send(.addPath, domain: "https://www.youtube.com/shorts/")
            #expect(again.ok == false && again.errorCode == .alreadyBlocked)
            let onWhole = try daemon.send(.addPath, domain: "reddit.com/r/all")
            #expect(onWhole.ok == false && onWhole.errorCode == .alreadyBlocked)
            #expect(try daemon.status().blockedPaths?.map(\.rule) == ["youtube.com/shorts"])
        }
    }

    // A path rule that is waiting to unblock is cancelled by adding it again, over the wire as in the engine.
    @Test func reAddingARuleThatWaitsToUnblockCancelsTheUnblock() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.send(.unblockPath, domain: "youtube.com/shorts", password: password).requireOK()
            #expect(try daemon.status().blockedPaths?.first?.unblockSecondsRemaining != nil)
            let reply = try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            #expect(reply.message == "Unblock cancelled; youtube.com/shorts stays blocked.")
            #expect(try daemon.status().blockedPaths?.first?.unblockSecondsRemaining == nil)
        }
    }

    // MARK: injection

    // The rule text reaches root's property list files. A text that tries to smuggle a second entry or a hosts line is refused or stored as ONE harmless entry: never an extra list item and never a hosts line.
    @Test(arguments: [
        "evil.com/a\n0.0.0.0 bank.com",
        "evil.com/a</string><string>bank.com",
        "evil.com/a\r\n:: bank.com",
        "evil.com/a\"],\"URLBlocklist\":[\"bank.com",
        "evil.com/a\u{2028}bank.com",
        "evil.com/a\u{200B}bank.com",
        "evil.com/a bank.com",
        "evil.com/a\tbank.com",
    ])
    func hostileRuleTextsAreRefusedAndNeverReachAFileOrTheHostsFile(text: String) throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let files = try daemon.browserFiles()
            let reply = try rawSend("addPath", domain: text, to: daemon)
            #expect(reply.ok == false && ["invalidPath", "invalidDomain"].contains(reply.errorCode ?? "none"), "\(text.debugDescription) got \(reply.text.prefix(300))")
            pause(0.4)
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
            for path in files.all { #expect(!(readText(path) ?? "").contains("bank.com"), "bank.com reached \(path)") }
        }
    }

    // A percent-encoded newline is legal in a path and stays as the three characters %0A: one list entry, nothing split, nothing in the hosts file.
    @Test func aPercentEncodedNewlineStaysInsideOneEntry() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let files = try daemon.browserFiles()
            try daemon.send(.addPath, domain: "evil.com/a%0A0.0.0.0%20bank.com").requireOK()
            for ref in files.refs {
                let path = try #require(files.path(ref))
                let expected = ref.browser == .firefox ? ["*://*.evil.com/a%0A0.0.0.0%20bank.com*"] : ["evil.com/a%0A0.0.0.0%20bank.com"]
                #expect(fileIsRight(path, ref.browser.expected(list: expected)), "\(ref.testDescription) holds \(String(describing: readPlist(path)))")
            }
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
        }
    }

    // MARK: unblockPath and cancelUnblockPath

    // 01 § Commands: unblockPath "starts the unblock countdown for that rule, with the same password and delay rules as unblock; notBlocked when no such rule exists." The rule stays in every browser list and in the status until the 2 s countdown has run out, then goes from both; the stopwatch starts before the request, so it can never be seen gone early.
    @Test func unblockPathKeepsTheRuleForTheFullDelayThenRemovesItEverywhere() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "example.com")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let files = try daemon.browserFiles()
            let both = designLists(sites: ["example.com"], rules: [(domain: "youtube.com", path: "/shorts")])
            let siteOnly = designLists(sites: ["example.com"])
            let state = { (browser: BrowserUnderTest) -> Bool in
                files.refs.filter { $0.browser == browser }.allSatisfy { ref in files.path(ref).map { fileIsRight($0, ref.browser.expected(list: ref.browser.pick(both))) } == true }
            }
            #expect(BrowserUnderTest.allCases.allSatisfy(state))

            let watch = Stopwatch()
            let reply = try daemon.send(.unblockPath, domain: "youtube.com/shorts", password: password).requireOK()
            #expect(reply.message == "youtube.com/shorts will unblock in 2 seconds. You can cancel any time before then.")
            #expect(reply.status?.blockedPaths?.first?.unblockSecondsRemaining == 2)
            var shortenedAt: Double?
            while watch.elapsed < 1.5 {
                if !BrowserUnderTest.allCases.allSatisfy(state) { shortenedAt = watch.elapsed; break }
                pause(0.02)
            }
            #expect(shortenedAt == nil, "the rule left the lists \(String(describing: shortenedAt)) s into a 2 s countdown")
            let gone = waitUntil(timeout: 4.0, interval: 0.02) {
                files.refs.allSatisfy { ref in files.path(ref).map { fileIsRight($0, ref.browser.expected(list: ref.browser.pick(siteOnly))) } == true }
            }
            #expect(gone != nil, "the rule never left the lists: \(files.all.map { String(describing: readPlist($0)) })")
            #expect(watch.elapsed >= 2.0, "the rule left after \(watch.elapsed) s, before the 2 s countdown was over")
            #expect(try daemon.status().blockedPaths == [])
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand("example.com")), "the whole site stays blocked")
            let saved = try #require(daemon.stateObject())
            #expect((saved["blockedPaths"] as? [Any] ?? []).isEmpty, "the saved state still holds the rule")
        }
    }

    @Test func aWrongPasswordForUnblockPathCountsTowardTheSharedLockoutThatAlsoStopsUnblock() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let wrong = try daemon.send(.unblockPath, domain: "youtube.com/shorts", password: "not-the-password")
            #expect(wrong.ok == false && wrong.errorCode == .wrongPassword)
            for _ in 0..<4 { _ = try daemon.send(.unblockPath, domain: "youtube.com/shorts", password: "not-the-password") }
            // Five wrong passwords lock all password checks, including the one for a whole site.
            let site = try daemon.send(.unblock, domain: "reddit.com", password: password)
            #expect(site.ok == false && site.errorCode == .lockedOut)
            let rule = try daemon.send(.unblockPath, domain: "youtube.com/shorts", password: password)
            #expect(rule.ok == false && rule.errorCode == .lockedOut)
            #expect(try daemon.status().blockedPaths?.first?.unblockSecondsRemaining == nil)
        }
    }

    @Test func unblockPathOfAMissingRuleIsNotBlockedAndWithoutAPathIsInvalidPath() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let missing = try daemon.send(.unblockPath, domain: "youtube.com/watch", password: password)
            #expect(missing.ok == false && missing.errorCode == .notBlocked)
            let site = try daemon.send(.unblockPath, domain: "reddit.com/r/all", password: password)
            #expect(site.ok == false && site.errorCode == .notBlocked, "a whole-site block is not a path rule")
            let none = try daemon.send(.unblockPath, domain: "youtube.com", password: password)
            #expect(none.ok == false && none.errorCode == .invalidPath)
        }
    }

    // cancelUnblockPath stops the countdown with no password; the rule is still there past the delay.
    @Test func cancelUnblockPathKeepsTheRulePastTheDelay() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.requireTwoSecondDelay()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let nothing = try daemon.send(.cancelUnblockPath, domain: "youtube.com/shorts")
            #expect(nothing.ok == false && nothing.errorCode == .nothingPending)
            try daemon.send(.unblockPath, domain: "youtube.com/shorts", password: password).requireOK()
            let cancel = try daemon.send(.cancelUnblockPath, domain: "https://www.youtube.com/shorts/").requireOK()
            #expect(cancel.message == "Unblock cancelled; youtube.com/shorts stays blocked.")
            pause(3.0)
            #expect(daemon.isRunning)
            let status = try daemon.status()
            #expect(status.blockedPaths?.map(\.rule) == ["youtube.com/shorts"])
            #expect(status.blockedPaths?.first?.unblockSecondsRemaining == nil)
            let files = try daemon.browserFiles()
            let lists = designLists(sites: [], rules: [(domain: "youtube.com", path: "/shorts")])
            for ref in files.refs {
                let path = try #require(files.path(ref))
                #expect(fileIsRight(path, ref.browser.expected(list: ref.browser.pick(lists))))
            }
        }
    }

    // A rule's countdown is saved and survives a restart that follows it: the rule is neither lost nor finished early, and it still finishes later. After a SIGKILL the countdown continues from the last save.
    @Test func aPendingRuleCountdownSurvivesAKill() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.requireTwoSecondDelay()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.send(.unblockPath, domain: "youtube.com/shorts", password: password).requireOK()
            daemon.kill9()
            try daemon.start()
            let status = try daemon.status()
            // The rule is still there (the kill came well inside the 2 s) or has already finished (a slow machine); it is never lost with the countdown unfinished.
            if let rule = status.blockedPaths?.first { #expect(rule.unblockSecondsRemaining != nil, "the countdown was lost by the restart") }
            let gone = waitUntil(timeout: 6.0, interval: 0.05) { (try? daemon.status().blockedPaths?.isEmpty) == true }
            #expect(gone != nil, "the rule never finished its countdown after the restart")
        }
    }

    // MARK: cap

    // 01 § Fixed Policy Values: "Most blocked sites: 500, counting sites and path rules together." Under --policy-fast the cap is 20. Ten sites and ten rules fill it; the 21st entry of either kind is refused with tooManySites and changes nothing; finishing one unblock frees exactly one slot.
    @Test func sitesAndRulesTogetherFillTheCapOfTwentyOverTheWire() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.requireTwoSecondDelay()
            for index in 0..<10 { try daemon.send(.add, domain: "site\(index).example.com").requireOK() }
            for index in 0..<10 { try daemon.send(.addPath, domain: "rule\(index).example.com/p").requireOK() }
            let hostsBefore = daemon.hostsText()
            let site = try rawSend("add", domain: "one-too-many.example.com", to: daemon)
            #expect(site.ok == false && site.errorCode == "tooManySites", "got \(site.text.prefix(300))")
            let rule = try rawSend("addPath", domain: "one-too-many.example.com/p", to: daemon)
            #expect(rule.ok == false && rule.errorCode == "tooManySites", "got \(rule.text.prefix(300))")
            #expect(daemon.hostsText() == hostsBefore)
            let status = try daemon.status()
            #expect(status.blocked.count == 10 && status.blockedPaths?.count == 10)
            // Re-adding an existing rule is alreadyBlocked, not tooManySites.
            #expect(try daemon.send(.addPath, domain: "rule3.example.com/p").errorCode == .alreadyBlocked)

            try daemon.send(.unblockPath, domain: "rule0.example.com/p", password: password).requireOK()
            let freed = waitUntil(timeout: 5.0, interval: 0.05) { (try? daemon.status().blockedPaths?.count) == 9 }
            #expect(freed != nil)
            try daemon.send(.add, domain: "fits-now.example.com").requireOK()
            let full = try daemon.send(.addPath, domain: "again-too-many.example.com/p")
            #expect(full.ok == false && full.errorCode == .tooManySites)
        }
    }

    // MARK: hosts file untouched

    // Path rules do not touch the hosts file: through a whole sequence of commands the file is byte for byte what it was with nothing blocked, and `siteblock status` of the daemon says the hosts file is healthy.
    @Test func aSequenceOfRuleCommandsNeverChangesTheHostsFile() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.requireTwoSecondDelay()
            let idle = daemon.hostsText()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.send(.addPath, domain: "x.com/Home").requireOK()
            #expect(daemon.hostsText() == idle)
            try daemon.send(.unblockPath, domain: "x.com/Home", password: password).requireOK()
            #expect(daemon.hostsText() == idle)
            let gone = waitUntil(timeout: 5.0, interval: 0.05) { (try? daemon.status().blockedPaths?.count) == 1 }
            #expect(gone != nil)
            #expect(daemon.hostsText() == idle)
            #expect(try daemon.status().hostsFileHealthy)
        }
    }
}
