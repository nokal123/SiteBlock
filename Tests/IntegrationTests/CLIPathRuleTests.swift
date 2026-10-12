import Foundation
import SiteBlockCore
import Testing

// The real `siteblock` tool and path rules.
// Design: 03-daemon-cli-app.md § 14 (CLI): `siteblock add <text>` makes a whole-site block when the text has no path and a path rule when it has one
// (`siteblock add youtube.com/shorts`); `--whole-site` forces a whole-site block from text that has a path; `unblock <text>` and `cancel <text>` act on the
// path rule when the text has a path, otherwise on the site; `status` prints "Blocked parts of sites (N):" with one line per rule, after the sites.

private func cli(_ daemon: SandboxDaemon, _ arguments: [String], stdin: String? = nil) throws -> ProgramResult {
    try runCLI(arguments, socket: daemon.socketPath, stdin: stdin)
}

private let password = SandboxDaemon.password

@Suite("siteblock CLI path rules")
struct CLIPathRuleTests {
    // `add youtube.com/shorts` makes a path rule: the daemon lists it as a rule and not as a site, the hosts file is unchanged, and the browsers' lists hold the path entry.
    @Test func addWithAPathMakesAPathRuleAndNotAWholeSiteBlock() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.setUp()
            let files = try daemon.browserFiles()
            let result = try cli(daemon, ["add", "youtube.com/shorts"])
            #expect(result.status == 0 && !result.timedOut, "stderr: \(result.stderr)")
            #expect(result.stdout.contains("youtube.com/shorts is now blocked."), "got: \(result.stdout)")
            let status = try daemon.status()
            #expect(status.blockedPaths?.map(\.rule) == ["youtube.com/shorts"])
            #expect(status.blocked.isEmpty, "a path must not block the whole site")
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
            let lists = designLists(sites: [], rules: [(domain: "youtube.com", path: "/shorts")])
            for ref in files.refs {
                let path = try #require(files.path(ref))
                #expect(fileIsRight(path, ref.browser.expected(list: ref.browser.pick(lists))), "\(ref.testDescription) holds \(String(describing: readPlist(path)))")
            }
        }
    }

    // `add youtube.com` (no path) still blocks the whole site, exactly as before.
    @Test func addWithoutAPathBlocksTheWholeSite() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.setUp()
            let result = try cli(daemon, ["add", "youtube.com"])
            #expect(result.status == 0, "stderr: \(result.stderr)")
            #expect(result.stdout.contains("youtube.com is now blocked."))
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand("youtube.com")))
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["youtube.com"])
            #expect(status.blockedPaths == [])
        }
    }

    // The same two inputs written the other ways a person types them: a lone trailing slash is still the whole site, and a link with a path is a rule.
    @Test(arguments: [("youtube.com/", false), ("https://www.youtube.com/", false), ("https://www.youtube.com", false), ("https://www.youtube.com/shorts/abc?x=1", true), ("youtube.com/shorts/", true), ("youtube.com/@MrBeast", true)])
    func aTrailingSlashAloneIsTheWholeSiteAndAnyOtherPathIsARule(text: String, isRule: Bool) throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let result = try cli(daemon, ["add", text])
            #expect(result.status == 0, "stderr: \(result.stderr)")
            let status = try daemon.status()
            #expect(status.blocked.count == (isRule ? 0 : 1) && status.blockedPaths?.count == (isRule ? 1 : 0), "\(text): sites \(status.blocked.map(\.domain)), rules \(String(describing: status.blockedPaths?.map(\.rule)))")
        }
    }

    // 03 § 14: "`--whole-site` forces a whole-site block from text that has a path." It may come before or after the text.
    @Test(arguments: [["add", "--whole-site", "https://www.youtube.com/shorts/abc"], ["add", "https://www.youtube.com/shorts/abc", "--whole-site"]])
    func wholeSiteForcesAWholeSiteBlockFromATextWithAPath(arguments: [String]) throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let result = try cli(daemon, arguments)
            #expect(result.status == 0, "stderr: \(result.stderr)")
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["youtube.com"])
            #expect(status.blockedPaths == [])
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand("youtube.com")))
        }
    }

    // One command can mix them: each text is judged on its own, and `--whole-site` applies to all of them.
    @Test func severalTextsAreEachJudgedOnTheirOwn() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let result = try cli(daemon, ["add", "example.com", "youtube.com/shorts", "x.com/Home"])
            #expect(result.status == 0, "stderr: \(result.stderr)")
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["example.com"])
            #expect(status.blockedPaths?.map(\.rule) == ["youtube.com/shorts", "x.com/Home"])
        }
        try withDaemon { daemon in
            try daemon.setUp()
            let result = try cli(daemon, ["add", "--whole-site", "youtube.com/shorts", "x.com/Home"])
            #expect(result.status == 0, "stderr: \(result.stderr)")
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["youtube.com", "x.com"])
            #expect(status.blockedPaths == [])
        }
    }

    // A path the daemon refuses is a refusal (exit 1, the sentence on standard error), and the other texts in the same command are still tried.
    @Test func aRefusedPathExitsWithOneAndTheOthersAreStillBlocked() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let result = try cli(daemon, ["add", "youtube.com/my shorts", "example.com/ok"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("youtube.com/my shorts: "), "with several texts each error names its text: \(result.stderr)")
            #expect(result.stderr.contains("can't use"), "the daemon's sentence about the path goes to standard error: \(result.stderr)")
            #expect(try daemon.status().blockedPaths?.map(\.rule) == ["example.com/ok"])
        }
    }

    @Test func aWholeSiteFlagWithoutATextAndAnUnknownFlagAreUsageErrors() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let none = try cli(daemon, ["add", "--whole-site"])
            #expect(none.status == 64, "stderr: \(none.stderr)")
            let unknown = try cli(daemon, ["add", "--wholesite", "youtube.com/shorts"])
            #expect(unknown.status == 64)
            #expect(try daemon.status().blocked.isEmpty && daemon.status().blockedPaths == [])
        }
    }

    // The first add asks for the password, as before, and a path text works for it too.
    @Test func theFirstAddWithAPathChoosesThePasswordThenAddsTheRule() throws {
        try withDaemon { daemon in
            let result = try cli(daemon, ["add", "youtube.com/shorts"], stdin: "\(password)\n\(password)\n")
            #expect(result.status == 0, "stderr: \(result.stderr)")
            let status = try daemon.status()
            #expect(status.passwordSet)
            #expect(status.blockedPaths?.map(\.rule) == ["youtube.com/shorts"])
        }
    }

    // 03 § 14: `status` prints "Blocked parts of sites (N):" with one line per rule, after the sites, and a rule's countdown as a clock.
    @Test func statusListsTheBlockedPartsAfterTheSitesWithTheirCountdowns() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "example.com")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.setDelay, password: password, seconds: 90).requireOK()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.send(.addPath, domain: "x.com/Home").requireOK()
            try daemon.send(.unblockPath, domain: "x.com/Home", password: password).requireOK()
            let lines = try cli(daemon, ["status"]).stdout.components(separatedBy: "\n")
            let sites = try #require(lines.firstIndex { $0.hasPrefix("Blocked sites (1):") }, "got: \(lines)")
            let parts = try #require(lines.firstIndex { $0 == "Blocked parts of sites (2):" }, "got: \(lines)")
            #expect(parts > sites, "the parts come after the sites")
            #expect(lines[parts + 1] == "  youtube.com/shorts")
            #expect(lines[parts + 2].hasPrefix("  x.com/Home") && lines[parts + 2].range(of: "unblocks in [0-9]+:[0-9][0-9]", options: .regularExpression) != nil, "got: \(lines[parts + 2])")
            #expect(!lines.contains("No sites blocked."))
        }
    }

    // With only rules there is no "No sites blocked." line next to a list of blocked parts; with nothing at all, there is, and no "Blocked parts" heading.
    @Test func statusWithOnlyRulesOrWithNothingPrintsTheRightHeadings() throws {
        try withDaemon { daemon in
            let empty = try cli(daemon, ["status"]).stdout
            #expect(empty.contains("No sites blocked.") && !empty.contains("Blocked parts of sites"), "got: \(empty)")
            try daemon.setUp()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let onlyRules = try cli(daemon, ["status"]).stdout
            #expect(onlyRules.contains("Blocked parts of sites (1):\n  youtube.com/shorts"), "got: \(onlyRules)")
            #expect(!onlyRules.contains("No sites blocked.") && !onlyRules.contains("Blocked sites ("), "got: \(onlyRules)")
        }
    }

    // `unblock <text with a path>` starts the countdown for the RULE and leaves the whole-site block of the same domain alone; `cancel` stops only that. Without a path, the same commands act on the site.
    @Test func unblockAndCancelPickTheRuleWhenTheTextHasAPathAndTheSiteWhenItDoesNot() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            try daemon.requireTwoSecondDelay()
            // A rule on the same domain is refused while the whole site is blocked, so use a rule on another domain next to the site.
            try daemon.send(.addPath, domain: "x.com/Home").requireOK()

            let rule = try cli(daemon, ["unblock", "https://x.com/Home/"], stdin: "\(password)\n")
            #expect(rule.status == 0, "stderr: \(rule.stderr)")
            #expect(rule.stdout.contains("x.com/Home will unblock in 2 seconds"), "got: \(rule.stdout)")
            let pending = try daemon.status()
            #expect(pending.blockedPaths?.first?.unblockSecondsRemaining != nil)
            #expect(pending.blocked.first?.unblockSecondsRemaining == nil, "the site must not be touched by a path unblock")

            let cancel = try cli(daemon, ["cancel", "x.com/Home"])
            #expect(cancel.status == 0, "stderr: \(cancel.stderr)")
            #expect(try daemon.status().blockedPaths?.first?.unblockSecondsRemaining == nil)

            let site = try cli(daemon, ["unblock", "youtube.com"], stdin: "\(password)\n")
            #expect(site.status == 0, "stderr: \(site.stderr)")
            let afterSite = try daemon.status()
            #expect(afterSite.blocked.first?.unblockSecondsRemaining != nil)
            #expect(afterSite.blockedPaths?.first?.unblockSecondsRemaining == nil, "the rule must not be touched by a site unblock")
            let siteCancel = try cli(daemon, ["cancel", "youtube.com"])
            #expect(siteCancel.status == 0)
        }
    }

    // The rule's unblock finishes after the delay when it is not cancelled, and a wrong password or an unknown rule is a refusal with exit code 1.
    @Test func unblockOfARuleFinishesAfterTheDelayAndRefusalsExitWithOne() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.requireTwoSecondDelay()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let wrong = try cli(daemon, ["unblock", "youtube.com/shorts"], stdin: "not-the-password\n")
            #expect(wrong.status == 1 && !wrong.stderr.isEmpty)
            let unknown = try cli(daemon, ["unblock", "youtube.com/watch"], stdin: "\(password)\n")
            #expect(unknown.status == 1 && unknown.stderr.contains("not blocked"), "got: \(unknown.stderr)")
            let nothing = try cli(daemon, ["cancel", "youtube.com/shorts"])
            #expect(nothing.status == 1, "nothing is pending yet")
            let watch = Stopwatch()
            let good = try cli(daemon, ["unblock", "youtube.com/shorts"], stdin: "\(password)\n")
            #expect(good.status == 0, "stderr: \(good.stderr)")
            let gone = waitUntil(timeout: 5.0, interval: 0.05) { (try? daemon.status().blockedPaths?.isEmpty) == true }
            #expect(gone != nil)
            #expect(watch.elapsed >= 2.0, "the rule went after \(watch.elapsed) s, before the 2 s delay")
            let after = try cli(daemon, ["status"])
            #expect(after.stdout.contains("No sites blocked.") && !after.stdout.contains("shorts"), "got: \(after.stdout)")
        }
    }

    // The usage text mentions the new forms, so a person finds them with `siteblock help`.
    @Test func theHelpTextShowsThePathFormsAndTheWholeSiteFlag() throws {
        let result = try runCLI(["help"], socket: "/tmp/does-not-exist.sock")
        #expect(result.status == 0)
        #expect(result.stdout.contains("--whole-site") && result.stdout.contains("youtube.com/shorts"))
    }
}
