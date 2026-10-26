import Foundation
import SiteBlockCore
import Testing

// Brave's TorDisabled policy, written by the real siteblockd in sandbox mode. Design: 03-daemon-cli-app.md § 13 BrowserPolicyEnforcer (the Brave line: "TorDisabled = true
// (a boolean, written as <true/>)", "written in the same group as the adult-filter keys: whenever the adult filter is on, which is always while SiteBlock is installed, and it
// is left out only during an uninstall, which removes it like the other managed keys"; the file rules: "other keys kept, SiteBlock's managed keys replaced, a file deleted
// when nothing else is left, a rewrite when a managed key differs in value or type", "browser policy repaired (<target>)" logged for tampering) and 01-overview-and-data.md
// § How Blocking Works (Adult content filter). Chrome, Edge and Firefox are not given the key, so in their files it is someone else's key.

private let password = SandboxDaemon.password

// The exact XML a browser reads for the key: the key line followed by the boolean true, never <integer>1</integer> or <string>true</string>.
private let torTrueXML = "<key>TorDisabled</key>\n\t<true/>"

// The hand edits made to TorDisabled in a Brave file that holds the right content. Each one turns Tor windows back on in Brave, because Brave ignores a policy of the wrong type.
enum TorDisabledEdit: CaseIterable, CustomTestStringConvertible {
    case setFalse, setWholeNumberOne, setTextTrue, removed

    var testDescription: String { "\(self)" }

    // Applies the edit to the file's dictionary.
    func apply(_ plist: inout [String: Any]) {
        switch self {
        case .setFalse: plist["TorDisabled"] = false
        case .setWholeNumberOne: plist["TorDisabled"] = 1
        case .setTextTrue: plist["TorDisabled"] = "true"
        case .removed: plist["TorDisabled"] = nil
        }
    }
}

// Brave's two files: the machine-wide file and the per-user file (skipped by a test when nobody is logged in).
private let braveRefs = [BrowserFileRef(browser: .brave, kind: .machine), BrowserFileRef(browser: .brave, kind: .user)]

@Suite("Brave TorDisabled")
struct BraveTorDisabledTests {
    // Every Brave file holds TorDisabled as the XML boolean true from the first pass, before any password is set and with nothing blocked.
    @Test func everyBraveFileHoldsTorDisabledAsTheXMLTrueBeforeAnythingIsBlocked() throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            let paths = files.paths(of: .brave)
            #expect(paths.count == (files.consoleUser == nil ? 1 : 2))
            for path in paths {
                let written = waitUntil(timeout: 1.5, interval: 0.02) { fileIsRight(path, BrowserUnderTest.brave.expected(list: [])) }
                #expect(written != nil, "\(path) holds \(String(describing: readPlist(path)))")
                #expect(readText(path)?.contains(torTrueXML) == true, "\(path) must hold TorDisabled as <true/>:\n\(readText(path) ?? "<missing>")")
                let value = readPlist(path)?["TorDisabled"]
                #expect(sameKinds(value, true), "TorDisabled read back as \(String(describing: value))")
            }
        }
    }

    // Blocking a site and a path rule keeps TorDisabled in Brave's files beside the list, and no other browser's file gains it.
    @Test func blockingASiteAndAPathRuleKeepsTorDisabledInBraveOnly() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            let files = try daemon.browserFiles()
            try daemon.prepare(blocking: "youtube.com")
            try daemon.send(.addPath, domain: "x.com/Home").requireOK()
            let lists = designLists(sites: ["youtube.com"], rules: [(domain: "x.com", path: "/Home")])
            for ref in files.refs {
                let path = try #require(files.path(ref))
                let plist = readPlist(path)
                #expect(sameKinds(plist, ref.browser.expected(list: ref.browser.pick(lists))), "\(ref.testDescription) holds \(String(describing: plist))")
                if ref.browser == .brave {
                    #expect(readText(path)?.contains(torTrueXML) == true, "\(ref.testDescription) lost TorDisabled after the block")
                } else {
                    #expect(plist?["TorDisabled"] == nil, "\(ref.testDescription) must not get TorDisabled")
                    #expect(readText(path)?.contains("TorDisabled") == false)
                }
            }
        }
    }

    // A hand edit that sets TorDisabled to false, to the whole number 1, to the text "true", or removes it, in either Brave file, is undone within 1.5 s to the boolean true,
    // with the rest of the file intact, and logged as "browser policy repaired (Brave)".
    @Test(arguments: braveRefs, TorDisabledEdit.allCases)
    func aHandEditOfTorDisabledInABraveFileIsRepairedAndLogged(ref: BrowserFileRef, edit: TorDisabledEdit) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let files = try daemon.browserFiles()
            guard let path = files.path(ref) else { return }
            let expected = BrowserUnderTest.brave.expected(list: designLists(sites: ["youtube.com"]).chrome)
            try require(waitUntil(timeout: 1.5, interval: 0.02) { fileIsRight(path, expected) } != nil, "the file was not right before the edit: \(String(describing: readPlist(path)))")
            let repairsBefore = daemon.logCount(of: "browser policy repaired (Brave)")
            try editPlist(at: path) { edit.apply(&$0) }
            let repaired = waitUntil(timeout: 1.5, interval: 0.01) { fileIsRight(path, expected) }
            #expect(repaired != nil, "\(edit) in \(ref.testDescription) was not repaired; the file holds \(readText(path) ?? "<missing>")")
            #expect(readText(path)?.contains(torTrueXML) == true)
            #expect(daemon.waitForLogCount(of: "browser policy repaired (Brave)", atLeast: repairsBefore + 1), "the repair was not logged:\n\(daemon.logText())")
        }
    }

    // A Brave file holding only a hand-set TorDisabled = false and a company key, with nothing blocked: the company key is kept with its type, and TorDisabled and the
    // other filter keys are put right.
    @Test func aBraveFileOfOnlyAFalseTorDisabledAndACompanyKeyKeepsTheCompanyKey() throws {
        try withDaemon { daemon in
            let files = try daemon.browserFiles()
            let path = try #require(files.path(BrowserFileRef(browser: .brave, kind: .machine)))
            try require(waitUntil(timeout: 1.5, interval: 0.02) { fileIsRight(path, BrowserUnderTest.brave.expected(list: [])) } != nil, "the Brave file was never written")
            let company: [String: Any] = ["HomepageLocation": "https://intranet.example/", "RestoreOnStartup": 4]
            try writePlist(company.merging(["TorDisabled": false]) { old, _ in old }, to: path)
            let fixed = waitUntil(timeout: 1.5, interval: 0.01) { fileIsRight(path, BrowserUnderTest.brave.expected(list: [], other: company)) }
            #expect(fixed != nil, "the file holds \(String(describing: readPlist(path)))")
        }
    }

    // TorDisabled is not Chrome's, Edge's or Firefox's key: a TorDisabled = false planted in their machine-wide files is someone else's key, so it is kept, the file is not
    // rewritten, and no repair is logged for that browser.
    @Test(arguments: [BrowserUnderTest.chrome, .edge, .firefox])
    func aTorDisabledInAnotherBrowsersFileIsLeftAlone(browser: BrowserUnderTest) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let files = try daemon.browserFiles()
            let path = try #require(files.path(BrowserFileRef(browser: browser, kind: .machine)))
            let list = browser.pick(designLists(sites: ["youtube.com"]))
            try require(waitUntil(timeout: 1.5, interval: 0.02) { fileIsRight(path, browser.expected(list: list)) } != nil, "the \(browser.name) file was not right to begin with")
            let repairsBefore = daemon.logCount(of: browser.repairedLine)
            try editPlist(at: path) { $0["TorDisabled"] = false }
            let edited = identity(of: path)
            // Several passes run in this time (tick 0.2 s).
            pause(1.0)
            #expect(sameKinds(readPlist(path), browser.expected(list: list, other: ["TorDisabled": false])), "\(browser.name) holds \(String(describing: readPlist(path)))")
            #expect(identity(of: path) == edited, "the \(browser.name) file was rewritten although only a key it does not own changed")
            #expect(daemon.logCount(of: browser.repairedLine) == repairsBefore, "a key \(browser.name) does not own was treated as tampering:\n\(daemon.logText())")
        }
    }

    // The uninstall removes TorDisabled from every Brave file: a file that also holds a company key keeps exactly that key; a file holding nothing else is deleted. A TorDisabled
    // planted in Chrome's file is not SiteBlock's there and survives the uninstall. Checked after the daemon has exited with code 0, so no later pass can hide a leftover.
    @Test(arguments: [false, true])
    func theUninstallRemovesTorDisabledFromBraveAndKeepsCompanyKeys(braveHasCompanyKey: Bool) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            try daemon.requireTwoSecondDelay()
            let files = try daemon.browserFiles()
            let bravePaths = files.paths(of: .brave)
            let chromePath = try #require(files.path(BrowserFileRef(browser: .chrome, kind: .machine)))
            let company: [String: Any] = ["HomepageLocation": "https://intranet.example/"]
            if braveHasCompanyKey { for path in bravePaths { try editPlist(at: path) { $0.merge(company) { _, new in new } } } }
            try editPlist(at: chromePath) { $0["TorDisabled"] = true }
            pause(0.5)
            for path in bravePaths { #expect(readText(path)?.contains(torTrueXML) == true, "TorDisabled must be in place before the uninstall: \(path)") }
            try daemon.send(.uninstall, password: password).requireOK()
            // The adult filter, TorDisabled included, stays on through the uninstall wait.
            #expect(bravePaths.allSatisfy { readText($0)?.contains(torTrueXML) == true }, "TorDisabled must stay while the uninstall counts down")
            let exit = try #require(daemon.waitForExit(timeout: 6.0), "the daemon never exited after the uninstall delay")
            #expect(exit.status == 0 && !exit.killedBySignal)
            for path in bravePaths {
                if braveHasCompanyKey {
                    #expect(sameKinds(readPlist(path), company), "\(path) now holds \(String(describing: readPlist(path)))")
                } else {
                    #expect(!exists(path), "\(path) holds nothing else and must be deleted; it holds \(String(describing: readPlist(path)))")
                }
            }
            #expect(sameKinds(readPlist(chromePath), ["TorDisabled": true]), "Chrome's file now holds \(String(describing: readPlist(chromePath)))")
        }
    }
}
