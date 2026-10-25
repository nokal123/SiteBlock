import Foundation
import SiteBlockCore
import Testing

// The policy files of Chrome, Edge, Brave and Firefox, written by the real siteblockd running in sandbox mode.
// Design: 03-daemon-cli-app.md § 13 BrowserPolicyEnforcer (targets and managed keys, the same file rules as Chrome had, Firefox's third file, sandbox paths),
// § 6 Uninstaller step 3 (every target is cleaned); 01-overview-and-data.md § How Blocking Works ("Other browsers" and "Blocking part of a site");
// 02-core-components.md § Engine ("Browser block list").
//
// Every expected list is built by `designLists` from the design's expansion and covering rules, never read back from the daemon. The Chrome files'
// own details (symlinks, FIFOs, modes, write failures and so on) are tested in ChromePolicyTests; here the same attacks are repeated against every
// file of every browser, because the design gives all four targets the same file rules.

private let password = SandboxDaemon.password

// The ways a test damages a browser policy file that already holds the right content.
enum BrowserDamage: CaseIterable, CustomTestStringConvertible {
    case deleted, garbage, mode0600, listKeyRemoved, listEmptied, extraListEntry, filterKeyChanged, filterKeyDeleted, valueTypeSwapped, symlinkToDecoy, namedPipe

    var testDescription: String { "\(self)" }
}

// True when the path is a regular file (not a named pipe, folder or link). Checked before any read, because opening a named pipe for reading waits for a writer and would freeze the test.
private func isRegularFile(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular
}

// What a failure message shows for a file: its text, or a note when it is not a regular file.
private func describeFile(_ path: String) -> String {
    isRegularFile(path) ? String(describing: readText(path)) : "<not a regular file>"
}

// Applies the damage to the file of a browser. Returns the decoy path when the damage planted a symlink (so the test can check the decoy was not written through), else nil.
@discardableResult
private func damage(_ kind: BrowserDamage, file path: String, browser: BrowserUnderTest, daemon: SandboxDaemon) throws -> String? {
    switch kind {
    case .deleted:
        try FileManager.default.removeItem(atPath: path)
    case .garbage:
        try Data("this is not a property list at all\n".utf8).write(to: URL(fileURLWithPath: path))
    case .mode0600:
        try chmodPath(path, 0o600)
    case .listKeyRemoved:
        try editPlist(at: path) { $0[browser.listKey] = nil }
    case .listEmptied:
        try editPlist(at: path) { $0[browser.listKey] = browser == .firefox ? ["Block": [String]()] as [String: Any] : [String]() }
    case .extraListEntry:
        try editPlist(at: path) { plist in
            let extra = browser == .firefox ? "*://*.extra.example/*" : "extra.example"
            let current = browser.list(in: plist) ?? []
            plist[browser.listKey] = browser == .firefox ? ["Block": current + [extra]] as [String: Any] : current + [extra]
        }
    case .filterKeyChanged:
        try editPlist(at: path) { plist in
            switch browser {
            case .chrome: plist["ForceGoogleSafeSearch"] = false
            case .edge: plist["ForceBingSafeSearch"] = 0
            case .brave: plist["SafeSitesFilterBehavior"] = 0
            case .firefox: plist["DNSOverHTTPS"] = ["Enabled": true, "Locked": false] as [String: Any]
            }
        }
    case .filterKeyDeleted:
        try editPlist(at: path) { plist in
            switch browser {
            case .chrome: plist["DnsOverHttpsMode"] = nil
            case .edge: plist["ForceGoogleSafeSearch"] = nil
            case .brave: plist["SafeSitesFilterBehavior"] = nil
            case .firefox: plist["EnterprisePoliciesEnabled"] = nil
            }
        }
    case .valueTypeSwapped:
        // Foundation counts the boolean true, the whole number 1 and the decimal 1.0 as equal, but a browser ignores a policy of the wrong type.
        try editPlist(at: path) { plist in
            switch browser {
            case .chrome: plist["SafeSitesFilterBehavior"] = true
            case .edge: plist["ForceBingSafeSearch"] = 2.0
            case .brave: plist["ForceGoogleSafeSearch"] = 1
            case .firefox: plist["DNSOverHTTPS"] = ["Enabled": 0, "Locked": 1] as [String: Any]
            }
        }
    case .symlinkToDecoy:
        let decoy = daemon.root + "/decoy-\(browser.name).plist"
        try writePlist(["Keep": "me"], to: decoy)
        let link = daemon.root + "/link-\(browser.name).tmp"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: decoy)
        try swapIn(link, over: path)
        return decoy
    case .namedPipe:
        let pipe = daemon.root + "/pipe-\(browser.name).tmp"
        try require(mkfifo(pipe, 0o644) == 0, "mkfifo failed: \(String(cString: strerror(errno)))")
        try swapIn(pipe, over: path)
    }
    return nil
}

// Moves the prepared link or pipe over the policy file in one rename. Deleting the file first and then creating the link left a gap in which a fast daemon put the
// right file back, so the create failed with "file already exists" (seen on GitHub's Mac runner); a rename replaces the file with no such gap, as an attacker would.
private func swapIn(_ prepared: String, over path: String) throws {
    try require(rename(prepared, path) == 0, "rename over \(path) failed: \(String(cString: strerror(errno)))")
}

@Suite("Browser policy files")
struct BrowserPoliciesTests {
    // The lists and keys the files must hold with youtube.com blocked as a whole site.
    static let youtubeOnly = designLists(sites: ["youtube.com"])

    // The expected content of one file.
    private func wanted(_ ref: BrowserFileRef, _ lists: (chrome: [String], firefox: [String]), other: [String: Any] = [:]) -> [String: Any] {
        ref.browser.expected(list: ref.browser.pick(lists), other: other)
    }

    // MARK: all files, keys and types

    // 03 § 13: the filter keys are "all always present while SiteBlock is installed", so with nothing blocked every file already exists and holds exactly its browser's filter keys, with the design's types and no list key. Nested dictionaries are written as dictionaries, not as text.
    @Test func everyFileExistsFromStartHoldingExactlyItsBrowsersFilterKeys() throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            for ref in files.refs {
                let path = try #require(files.path(ref))
                let right = waitUntil(timeout: 1.5, interval: 0.02) { fileIsRight(path, wanted(ref, ([], []))) }
                #expect(right != nil, "\(ref.testDescription) at \(path) holds \(String(describing: readPlist(path)))")
            }
            // Only the files in the design exist: four machine-wide ones, the console user's four in a folder named after the user, and Firefox's third file.
            let machineNames = BrowserUnderTest.allCases.map { $0.bundleID + ".plist" }
            #expect(daemon.listing(of: files.managedDirectory).sorted() == (machineNames + (files.consoleUser.map { [$0] } ?? [])).sorted())
            if let user = files.consoleUser { #expect(daemon.listing(of: files.managedDirectory + "/" + user).sorted() == machineNames.sorted()) }
            #expect(daemon.listing(of: files.preferencesDirectory) == ["org.mozilla.firefox.plist"])
        }
    }

    // The types, checked on the raw text a browser reads: Edge's Bing SafeSearch is the whole number 2 (not 2.0, not true), Firefox's flags are real booleans inside nested dictionaries, and Chrome's three keys keep their three types.
    @Test func theValueTypesAreWrittenAsTheDesignSays() throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            try daemon.setUp()
            try daemon.send(.add, domain: "youtube.com").requireOK()
            let text = { (browser: BrowserUnderTest) in readText(files.paths(of: browser)[0]) ?? "" }
            #expect(text(.edge).contains("<key>ForceBingSafeSearch</key>\n\t<integer>2</integer>"))
            #expect(text(.edge).contains("<key>ForceGoogleSafeSearch</key>\n\t<true/>"))
            #expect(text(.edge).contains("<key>DnsOverHttpsMode</key>\n\t<string>off</string>"))
            #expect(text(.brave).contains("<key>SafeSitesFilterBehavior</key>\n\t<integer>1</integer>"))
            #expect(text(.brave).contains("<key>ForceGoogleSafeSearch</key>\n\t<true/>"))
            #expect(text(.chrome).contains("<key>SafeSitesFilterBehavior</key>\n\t<integer>1</integer>"))
            #expect(text(.firefox).contains("<key>EnterprisePoliciesEnabled</key>\n\t<true/>"))
            let firefox = try #require(readPlist(files.paths(of: .firefox)[0]))
            let doh = try #require(firefox["DNSOverHTTPS"] as? [String: Any], "DNSOverHTTPS must be a dictionary")
            #expect(sameKinds(doh, ["Enabled": false, "Locked": true] as [String: Any]))
            let filter = try #require(firefox["WebsiteFilter"] as? [String: Any], "WebsiteFilter must be a dictionary")
            #expect(Set(filter.keys) == ["Block"])
            #expect(filter["Block"] is [String])
        }
    }

    // 03 § 13 and § 9: after `add youtube.com` every browser's file holds its list, read the moment the reply arrives (the daemon here ticks once a minute, so only the pass that follows the command can have written it). Chrome, Edge and Brave get the covering host list; Firefox gets a `*://*.<host>/*` pattern per covering host.
    @Test func addingASiteWritesEveryBrowsersListBeforeTheResponseReturns() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            let files = try daemon.browserFiles()
            try daemon.setUp()
            try daemon.send(.add, domain: "youtube.com").requireOK()
            let lists = Self.youtubeOnly
            #expect(lists.chrome.count == 9 && lists.firefox.count == 9, "the test's own expected lists do not match the design's example")
            for ref in files.refs {
                let path = try #require(files.path(ref))
                #expect(fileIsRight(path, wanted(ref, lists)), "\(ref.testDescription) holds \(String(describing: readPlist(path)))")
            }
            #expect(Set(readPlist(files.paths(of: .firefox)[0]).flatMap { BrowserUnderTest.firefox.list(in: $0) } ?? []) == Set(lists.chrome.map { "*://*.\($0)/*" }))
        }
    }

    // MARK: path rules

    // 01 § How Blocking Works ("Blocking part of a site") and 02 § Engine: a path rule appears in the Chrome, Edge and Brave URLBlocklist as `youtube.com/shorts` and in Firefox's WebsiteFilter as `*://*.youtube.com/shorts*`, and it does NOT appear in the hosts file: the hosts file stays exactly as it is with nothing blocked.
    @Test func aPathRuleIsWrittenIntoEveryBrowsersListAndNeverIntoTheHostsFile() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            let files = try daemon.browserFiles()
            try daemon.setUp()
            let idle = daemon.hostsText()
            #expect(idle == ExpectedHosts.idleText)
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            for ref in files.refs {
                let path = try #require(files.path(ref))
                let expected = ref.browser == .firefox ? ["*://*.youtube.com/shorts*"] : ["youtube.com/shorts"]
                #expect(ref.browser.list(in: readPlist(path)) == expected, "\(ref.testDescription) holds \(String(describing: readPlist(path)))")
                #expect(fileIsRight(path, ref.browser.expected(list: expected)), "\(ref.testDescription) must hold exactly its filter keys and the rule")
            }
            #expect(daemon.hostsText() == idle, "a path rule must not change the hosts file at all")
            let hosts = daemon.hosts()
            #expect(!hosts.blocks("youtube.com") && !hosts.blocks("www.youtube.com") && !hosts.blocks("m.youtube.com"))
            #expect(!daemon.hostsText().contains("youtube"))
        }
    }

    // A pasted link becomes the same rule: scheme, www, query and fragment are cut, the path keeps its case.
    @Test func aPastedLinkBecomesTheRuleWithItsPathCaseKept() throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            try daemon.setUp()
            try daemon.send(.addPath, domain: "https://www.YouTube.com/Shorts/AbC?feature=share#t=3").requireOK()
            let status = try daemon.status()
            #expect(status.blockedPaths == [BlockedPathStatus(domain: "youtube.com", path: "/Shorts/AbC", rule: "youtube.com/Shorts/AbC", unblockSecondsRemaining: nil)])
            for ref in files.refs {
                let path = try #require(files.path(ref))
                let expected = ref.browser == .firefox ? ["*://*.youtube.com/Shorts/AbC*"] : ["youtube.com/Shorts/AbC"]
                #expect(ref.browser.list(in: readPlist(path)) == expected, "\(ref.testDescription)")
            }
        }
    }

    // 02 § Engine, "Browser block list": a rule whose domain a whole-site block covers drops out of every list, and comes back when the whole site is unblocked ("matter again if the whole site is unblocked"). The hosts file is checked too: it gets the whole site's names and then loses them.
    @Test func aWholeSiteBlockMakesTheSameDomainsPathEntriesDropOutOfEveryList() throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            try daemon.setUp()
            try daemon.requireTwoSecondDelay()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let rule = [(domain: "youtube.com", path: "/shorts")]
            #expect(files.refs.allSatisfy { ref in files.path(ref).map { fileIsRight($0, wanted(ref, designLists(sites: [], rules: rule))) } == true })

            try daemon.send(.add, domain: "youtube.com").requireOK()
            let whole = designLists(sites: ["youtube.com"], rules: rule)
            #expect(whole.chrome == Self.youtubeOnly.chrome, "the design's own rule drops the covered rule from the expected list")
            for ref in files.refs {
                let path = try #require(files.path(ref))
                #expect(fileIsRight(path, wanted(ref, whole)), "\(ref.testDescription) holds \(String(describing: readPlist(path)))")
                #expect(!(ref.browser.list(in: readPlist(path)) ?? []).contains { $0.contains("shorts") }, "the path entry must be gone from \(ref.testDescription)")
            }
            // The rule is still kept by the daemon, and the hosts file now blocks the whole site.
            #expect(try daemon.status().blockedPaths?.map(\.rule) == ["youtube.com/shorts"])
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand("youtube.com")))

            // Unblocking the whole site brings the rule's entry back.
            try daemon.send(.unblock, domain: "youtube.com", password: password).requireOK()
            let back = waitUntil(timeout: 5.0, interval: 0.02) {
                files.refs.allSatisfy { ref in files.path(ref).map { fileIsRight($0, wanted(ref, designLists(sites: [], rules: rule))) } == true }
            }
            #expect(back != nil, "the rule's entry did not return once the whole site was unblocked: \(files.all.map { String(describing: readPlist($0)) })")
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
        }
    }

    // Trying the rule after the whole site is the other order: it is refused (alreadyBlocked) and no file changes.
    @Test func aRuleOnAWholeBlockedSiteIsRefusedAndNoFileChanges() throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            try daemon.prepare(blocking: "youtube.com")
            pause(0.4)
            let before = files.all.map { identity(of: $0) }
            let reply = try daemon.send(.addPath, domain: "youtube.com/shorts")
            #expect(reply.ok == false && reply.errorCode == .alreadyBlocked)
            pause(0.6)
            #expect(files.all.map { identity(of: $0) } == before, "a refused command must not rewrite any policy file")
        }
    }

    // Sites and rules on different domains sit together: the sorted union in Chrome, Edge and Brave, and in Firefox.
    @Test func wholeSitesAndRulesOnOtherDomainsAreListedTogetherAndSorted() throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            try daemon.prepare(blocking: "example.com")
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.send(.addPath, domain: "x.com/Home").requireOK()
            let lists = designLists(sites: ["example.com"], rules: [(domain: "youtube.com", path: "/shorts"), (domain: "x.com", path: "/Home")])
            #expect(lists.chrome == ["example.com", "x.com/Home", "youtube.com/shorts"])
            #expect(lists.firefox == ["*://*.example.com/*", "*://*.x.com/Home*", "*://*.youtube.com/shorts*"])
            for ref in files.refs {
                let path = try #require(files.path(ref))
                #expect(fileIsRight(path, wanted(ref, lists)), "\(ref.testDescription) holds \(String(describing: readPlist(path)))")
            }
            // Only the whole site is in the hosts file.
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand("example.com")))
        }
    }

    // Adding a rule is a command, so the rewrite it causes is not a repair: the log must not say "repaired" for it. (The first pass of a new daemon does log a repair, because it writes the files in the first place.)
    @Test func addingARuleLogsNoRepairForAnyBrowser() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            pause(0.5)
            let before = BrowserUnderTest.allCases.map { daemon.logCount(of: $0.repairedLine) }
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            try daemon.send(.add, domain: "reddit.com").requireOK()
            pause(0.6)
            #expect(BrowserUnderTest.allCases.map { daemon.logCount(of: $0.repairedLine) } == before, "the writes caused by commands are not repairs:\n\(daemon.logText())")
        }
    }

    // A rule that finishes its unblock countdown changes the lists on purpose, so that rewrite is not a repair either.
    @Test func aRuleThatFinishesItsCountdownLogsNoRepair() throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            try daemon.setUp()
            try daemon.requireTwoSecondDelay()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            pause(0.5)
            let before = BrowserUnderTest.allCases.map { daemon.logCount(of: $0.repairedLine) }
            try daemon.send(.unblockPath, domain: "youtube.com/shorts", password: password).requireOK()
            let gone = waitUntil(timeout: 5.0, interval: 0.02) { files.refs.allSatisfy { ref in files.path(ref).map { fileIsRight($0, wanted(ref, ([], []))) } == true } }
            #expect(gone != nil)
            pause(0.5)
            #expect(BrowserUnderTest.allCases.map { daemon.logCount(of: $0.repairedLine) } == before, "a finished unblock is not tampering:\n\(daemon.logText())")
        }
    }

    // MARK: tamper repair, every file of every browser

    // 03 § 13: "a rewrite when a managed key differs in value or type or the mode or owner is wrong or the path is not a plain file, O_NONBLOCK opens, and 'browser policy repaired (<target>)' logged for tampering." Every kind of damage, in every file of every browser (including Firefox's third file), is repaired within 1.5 s to exactly the right content, mode 0644 and XML; the repair is logged under the browser's own name; and a symlink's target is never written through. A named pipe in place of the file must not freeze the daemon.
    @Test(arguments: BrowserFileRef.all, BrowserDamage.allCases)
    func damageToAnyFileOfAnyBrowserIsRepairedAndLogged(ref: BrowserFileRef, kind: BrowserDamage) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let files = try daemon.browserFiles()
            guard let path = files.path(ref) else { return }
            pause(0.4)
            let expected = wanted(ref, Self.youtubeOnly)
            #expect(fileIsRight(path, expected), "the file was not right before the damage: \(String(describing: readPlist(path)))")
            let repairsBefore = daemon.logCount(of: ref.browser.repairedLine)
            let decoy = try damage(kind, file: path, browser: ref.browser, daemon: daemon)
            let decoyBytes = decoy.flatMap { FileManager.default.contents(atPath: $0) }
            // The type is checked first: reading a named pipe would wait for a writer forever.
            let repaired = waitUntil(timeout: 1.5, interval: 0.01) { isRegularFile(path) && fileIsRight(path, expected) }
            #expect(repaired != nil, "\(kind) in \(ref.testDescription) was not repaired within 1.5 s; the file now holds \(describeFile(path))")
            #expect(waitUntil(timeout: 1.5, interval: 0.02) { daemon.logCount(of: ref.browser.repairedLine) > repairsBefore } != nil, "the repair was not logged as \(ref.browser.repairedLine):\n\(daemon.logText())")
            if let decoy { #expect(FileManager.default.contents(atPath: decoy) == decoyBytes, "the file behind the link was written through the link") }
            // A frozen daemon would not answer; a short client timeout makes a freeze cost one second.
            #expect((try? daemon.client(timeout: 1).send(Request(command: .status)))?.ok == true, "the daemon stopped answering after \(kind)")
        }
    }

    // Repairing one browser's file touches only that file: the other eight keep their inode and modification time, and only the damaged browser's name is logged.
    @Test func repairingOneBrowsersFileLeavesTheOthersAloneAndLogsOnlyThatBrowser() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let files = try daemon.browserFiles()
            pause(0.5)
            let edge = BrowserFileRef(browser: .edge, kind: .machine)
            let edgePath = try #require(files.path(edge))
            let others = files.all.filter { $0 != edgePath }
            let identities = others.map { identity(of: $0) }
            let logBefore = BrowserUnderTest.allCases.map { daemon.logCount(of: $0.repairedLine) }
            try damage(.garbage, file: edgePath, browser: .edge, daemon: daemon)
            #expect(waitUntil(timeout: 1.5, interval: 0.01) { fileIsRight(edgePath, wanted(edge, Self.youtubeOnly)) } != nil)
            pause(0.5)
            #expect(others.map { identity(of: $0) } == identities, "a file that was not damaged was rewritten")
            let logAfter = BrowserUnderTest.allCases.map { daemon.logCount(of: $0.repairedLine) }
            for (index, browser) in BrowserUnderTest.allCases.enumerated() {
                #expect((logAfter[index] > logBefore[index]) == (browser == .edge), "\(browser.name): repairs logged \(logBefore[index]) -> \(logAfter[index])")
            }
        }
    }

    // Passes that find every file right write nothing: over 1.5 s (several passes) no file of any browser changes its inode or modification time.
    @Test func passesThatFindEveryFileRightDoNotWriteAnyOfThem() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            try daemon.send(.addPath, domain: "x.com/Home").requireOK()
            let files = try daemon.browserFiles()
            pause(0.6)
            let first = files.all.map { identity(of: $0) }
            try #require(first.allSatisfy { $0 != nil })
            pause(1.5)
            #expect(files.all.map { identity(of: $0) } == first, "an already-correct policy file was rewritten")
        }
    }

    // MARK: keys that are not SiteBlock's

    // 03 § 13: "other keys kept". An administrator's keys (strings, numbers, booleans, lists and nested dictionaries) survive the next block in every file, with their types, and a nested dictionary beside Firefox's own is not mixed up with it.
    @Test(arguments: BrowserFileRef.all)
    func handAddedKeysSurviveTheNextBlockInEveryFile(ref: BrowserFileRef) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let files = try daemon.browserFiles()
            guard let path = files.path(ref) else { return }
            let foreign: [String: Any] = [
                "HomepageLocation": "https://home-\(ref.browser.name).example/",
                "ShowHomeButton": true,
                "RestoreOnStartup": 4,
                "RestoreOnStartupURLs": ["https://a.example/", "https://b.example/"],
                "Homepage": ["URL": "https://c.example/", "Locked": false, "StartPage": "homepage"] as [String: Any],
            ]
            try editPlist(at: path) { $0.merge(foreign) { _, new in new } }
            // The edit must not be treated as damage: wait until the passes have looked at it.
            pause(0.5)
            #expect(sameKinds(readPlist(path), wanted(ref, Self.youtubeOnly, other: foreign)), "a foreign key was changed by a pass that found nothing wrong: \(String(describing: readPlist(path)))")
            try daemon.block("reddit.com")
            let both = designLists(sites: ["youtube.com", "reddit.com"])
            #expect(sameKinds(readPlist(path), wanted(ref, both, other: foreign)), "\(ref.testDescription) now holds \(String(describing: readPlist(path)))")
        }
    }

    // A file that holds only an administrator's key gets SiteBlock's keys added beside it; a planted list is replaced by the real (empty) state.
    @Test(arguments: BrowserUnderTest.allCases)
    func aFileOfOtherKeysGainsTheFilterKeysAndAPlantedListIsRemovedWhileNothingIsBlocked(browser: BrowserUnderTest) throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            pause(0.4)
            let path = files.paths(of: browser)[0]
            let planted: [String: Any] = browser == .firefox ? ["WebsiteFilter": ["Block": ["*://*.planted.example/*"]] as [String: Any]] : ["URLBlocklist": ["planted.example"]]
            var content: [String: Any] = ["Admin": "keep-me"]
            content.merge(planted) { _, new in new }
            try writePlist(content, to: path)
            let cleaned = waitUntil(timeout: 1.5, interval: 0.01) { fileIsRight(path, browser.expected(list: [], other: ["Admin": "keep-me"])) }
            #expect(cleaned != nil, "\(browser.name) file now holds \(String(describing: readPlist(path)))")
        }
    }

    // MARK: failure of one file

    // 03 § 13 (same rules as § 9): a write that fails is logged and reported, but it does not stop the other files from being written. The Preferences folder (Firefox's third file) is made read-only before the daemon starts; every other file is still written, the status says the enforcement is not healthy, and once the folder is writable the third file appears within a second without any command. (Skipped for root, which ignores folder modes.)
    @Test(.enabled(if: geteuid() != 0))
    func aFailureWritingFirefoxsThirdFileDoesNotStopTheOtherFilesAndIsFixedWhenWritingWorks() throws {
        try withDaemon(start: false) { daemon in
            let files = try daemon.browserFiles()
            try FileManager.default.createDirectory(atPath: files.preferencesDirectory, withIntermediateDirectories: false)
            try chmodPath(files.preferencesDirectory, 0o555)
            defer { try? chmodPath(files.preferencesDirectory, 0o755) }
            try daemon.start()
            try daemon.setUp()
            try daemon.send(.add, domain: "youtube.com").requireOK()
            let lists = Self.youtubeOnly
            for ref in files.refs where ref.kind != .libraryPreferences {
                let path = try #require(files.path(ref))
                #expect(fileIsRight(path, wanted(ref, lists)), "\(ref.testDescription) must still be written")
            }
            let third = files.preferencesDirectory + "/org.mozilla.firefox.plist"
            #expect(!exists(third))
            #expect(daemon.logContains("could not be updated (Firefox)", within: 1.5), "the failed write was not logged:\n\(daemon.logText())")
            #expect(try daemon.status().hostsFileHealthy == false, "a file that cannot be written means the enforcement is not healthy")
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand("youtube.com")), "the hosts file is enforced regardless")

            try chmodPath(files.preferencesDirectory, 0o755)
            let back = waitUntil(timeout: 1.5, interval: 0.01) { fileIsRight(third, BrowserUnderTest.firefox.expected(list: lists.firefox)) }
            #expect(back != nil, "the third file was not written once its folder became writable")
            #expect(waitUntil(timeout: 1.5, interval: 0.02) { (try? daemon.status().hostsFileHealthy) == true } != nil)
        }
    }

    // MARK: restart

    // A stopped daemon leaves the blocks in place (only an uninstall clears them). Rules survive the restart, and every file deleted while the daemon was down comes back at startup, before any client connects (03 § Daemon Runtime, startup step 5). Both ways of stopping are tried.
    @Test(arguments: StopMethod.allCases)
    func pathRulesSurviveARestartAndDeletedFilesComeBackAtStartup(stop: StopMethod) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "example.com")
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let files = try daemon.browserFiles()
            let lists = designLists(sites: ["example.com"], rules: [(domain: "youtube.com", path: "/shorts")])
            daemon.stop(stop)
            #expect(files.refs.allSatisfy { ref in files.path(ref).map { fileIsRight($0, wanted(ref, lists)) } == true }, "stopping the daemon (\(stop.testDescription)) must not clear the block")
            for path in files.all { try FileManager.default.removeItem(atPath: path) }
            try daemon.start(serve: false)
            let back = waitUntil(timeout: 2.0, interval: 0.01) { files.refs.allSatisfy { ref in files.path(ref).map { fileIsRight($0, wanted(ref, lists)) } == true } }
            #expect(back != nil, "the files were not written again by the startup pass (\(stop.testDescription))")
            try daemon.waitUntilServing()
            #expect(try daemon.status().blockedPaths?.map(\.rule) == ["youtube.com/shorts"])
            #expect(try daemon.status().blocked.map(\.domain) == ["example.com"])
        }
    }

    // MARK: the state file of an older daemon

    // 01 § Data Model: "blockedPaths ... Optional in the file (an older state.json without it decodes as no path rules)". CRITICAL: the installed daemon's state.json lacks the key. A new daemon that starts over such a file must keep every site: blocked in the hosts file and in all four browsers' lists, nothing set aside as corrupt, and the sites still listed by status. It is tried with and without the `savedDNS` key, which the second-oldest format also lacked.
    @Test(arguments: [false, true])
    func aStateFileWithoutBlockedPathsStartsWithEverySiteIntact(withSavedDNS: Bool) throws {
        try withDaemon(start: false) { daemon in
            try FileManager.default.createDirectory(atPath: daemon.stateDir, withIntermediateDirectories: true)
            let hash = "{\"algorithm\":\"pbkdf2-sha256\",\"hash\":\"aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g=\",\"iterations\":1000,\"salt\":\"c2FsdHNhbHRzYWx0c2FsdA==\"}"
            // A site exactly as an older daemon wrote it: its domain and the full expanded host list.
            func site(_ domain: String) -> String {
                let hosts = ExpectedHosts.expand(domain).map { "\"\($0)\"" }.joined(separator: ",")
                return "{\"domain\":\"\(domain)\",\"hosts\":[\(hosts)]}"
            }
            let savedDNS = withSavedDNS ? "\"savedDNS\":{}," : ""
            let old = "{\"blocked\":[\(site("youtube.com")),\(site("reddit.com"))],\"delaySeconds\":2,\"failedAttempts\":0,\"passwordHash\":\(hash),\(savedDNS)\"uninstalling\":false,\"version\":1}"
            try Data(old.utf8).write(to: URL(fileURLWithPath: daemon.statePath))
            let files = try daemon.browserFiles()
            try daemon.start()
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["youtube.com", "reddit.com"], "the sites of the old state file were lost")
            #expect(status.blockedPaths == [])
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand(all: ["youtube.com", "reddit.com"])))
            let lists = designLists(sites: ["youtube.com", "reddit.com"])
            for ref in files.refs {
                let path = try #require(files.path(ref))
                #expect(fileIsRight(path, wanted(ref, lists)), "\(ref.testDescription) holds \(String(describing: readPlist(path)))")
            }
            let names = daemon.listing(of: daemon.stateDir)
            #expect(!names.contains { $0.contains("corrupt") }, "the old state file was set aside as corrupt: \(names)")
            // The stored password is the one in the file, so unblocking still works: the daemon really loaded it. (The hash above is not of a real password, so only the first-release check is made here: a command that needs no password.)
            try daemon.send(.addPath, domain: "x.com/Home").requireOK()
            daemon.stop(.sigkill)
            try daemon.start()
            let again = try daemon.status()
            #expect(again.blocked.map(\.domain) == ["youtube.com", "reddit.com"])
            #expect(again.blockedPaths?.map(\.rule) == ["x.com/Home"])
        }
    }

    // MARK: uninstall

    // 03 § 6 Uninstaller step 3: the uninstall removes SiteBlock's keys from every target file (Chrome, Edge, Brave, Firefox and Firefox's third file) in the same step that removes the hosts section. Files that hold nothing else are deleted; files with an administrator's keys keep exactly those. The checks run after the daemon has exited with code 0, so a late pass cannot be hiding a leftover. The lists (with both a site and a path rule) stay in force during the countdown.
    @Test(arguments: [false, true])
    func theSandboxUninstallCleansEveryBrowserFile(otherKeysPresent: Bool) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            try daemon.send(.addPath, domain: "x.com/Home").requireOK()
            try daemon.requireTwoSecondDelay()
            let files = try daemon.browserFiles()
            let lists = designLists(sites: ["youtube.com"], rules: [(domain: "x.com", path: "/Home")])
            var foreign: [String: [String: Any]] = [:]
            if otherKeysPresent {
                for (index, ref) in files.refs.enumerated() {
                    let path = try #require(files.path(ref))
                    let keys: [String: Any] = ["Admin\(index)": "keep-\(index)", "Nested": ["a": [1, true, "x"] as [Any]] as [String: Any]]
                    foreign[path] = keys
                    try editPlist(at: path) { $0.merge(keys) { _, new in new } }
                }
                pause(0.5)
            }
            for ref in files.refs {
                let path = try #require(files.path(ref))
                #expect(sameKinds(readPlist(path), wanted(ref, lists, other: foreign[path] ?? [:])), "the files must be in place before the uninstall: \(ref.testDescription)")
            }
            try daemon.send(.uninstall, password: password).requireOK()
            // The lists stay in force during the countdown.
            #expect(files.refs.allSatisfy { ref in files.path(ref).map { sameKinds(readPlist($0), wanted(ref, lists, other: foreign[$0] ?? [:])) } == true }, "the lists must stay in place while the uninstall counts down")
            let exit = try #require(daemon.waitForExit(timeout: 6.0), "the daemon never exited after the uninstall delay")
            #expect(exit.status == 0 && !exit.killedBySignal)
            #expect(daemon.hostsText() == StandardHosts.text, "the hosts section is removed in the same step")
            for ref in files.refs {
                let path = try #require(files.path(ref))
                if otherKeysPresent {
                    #expect(sameKinds(readPlist(path), foreign[path]), "\(ref.testDescription) now holds \(String(describing: readPlist(path)))")
                } else {
                    #expect(!exists(path), "\(ref.testDescription) must be deleted: nothing else is left in it")
                }
            }
            #expect(regularFiles(under: files.managedDirectory).count == (otherKeysPresent ? files.refs.filter { $0.kind != .libraryPreferences }.count : 0), "found \(regularFiles(under: files.managedDirectory))")
            #expect(regularFiles(under: files.preferencesDirectory).count == (otherKeysPresent ? 1 : 0), "found \(regularFiles(under: files.preferencesDirectory))")
        }
    }

    // MARK: DNS-over-HTTPS names in the hosts file

    // 01 § How Blocking Works ("Other browsers") and 02 § Engine (`dohBypassHosts`): the hosts file ALWAYS blocks the four names browsers use for their own DNS-over-HTTPS, even with nothing blocked: each has its IPv4 line and its IPv6 line, exactly once.
    @Test func theFourDoHNamesAreAlwaysInTheHostsFileExactlyOnce() throws {
        try withDaemon { daemon in
            let hosts = daemon.hosts()
            for name in ExpectedHosts.dohBypassHosts {
                #expect(hosts.blocks(name), "\(name) is not blocked")
                for line in ExpectedHosts.lines(for: name) { #expect(hosts.count(of: line) == 1, "\(line) appears \(hosts.count(of: line)) times") }
            }
            #expect(ExpectedHosts.dohBypassHosts.count == 4)
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
            // And they stay when a site is blocked and after the last one is unblocked.
            try daemon.prepare(blocking: "reddit.com")
            #expect(ExpectedHosts.dohBypassHosts.allSatisfy { daemon.hosts().blocks($0) })
        }
    }

    // Deleting just those lines is repaired like any other edit of the section, and a user line that points one of the names at a real address is a bypass line and is removed.
    @Test(arguments: ExpectedHosts.dohBypassHosts)
    func removingADoHNamesLinesOrPointingItAtARealAddressIsRepairedWithinOneSecond(name: String) throws {
        try withDaemon { daemon in
            let expected = ExpectedHosts.idleText
            try writeText(expected.replacingOccurrences(of: ExpectedHosts.lines(for: name).joined(separator: "\n") + "\n", with: ""), to: daemon.hostsPath)
            #expect(waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected } != nil, "the lines for \(name) were not restored:\n\(daemon.hostsText())")
            try writeText("17.0.0.1 \(name)\n" + expected, to: daemon.hostsPath)
            #expect(waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected } != nil, "the bypass line for \(name) was not removed:\n\(daemon.hostsText())")
        }
    }
}
