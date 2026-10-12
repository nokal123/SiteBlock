import Foundation
import SiteBlockCore
import Testing

// Blocking a site and keeping the sandbox hosts file correct, against the real siteblockd.
// Design: 01-overview-and-data.md § How Blocking Works; 03-daemon-cli-app.md § HostsEnforcer; 02-core-components.md § HostsFileEditor, § DomainExpander.
@Suite("Blocking and hosts file")
struct BlockingTests {
    // A tick this slow never fires during a test, so any change to the hosts file must come from the command path itself.
    static let neverTick = 60.0

    // 05 Integration Tests, first bullet: after `add reddit.com` the lines are already on disk when the response arrives.
    @Test func addRedditWritesBlockLinesBeforeTheResponseReturns() throws {
        try withDaemon(tick: Self.neverTick) { daemon in
            try daemon.setUp()
            // Design change (01 § How Blocking Works, Adult content filter): nothing is blocked yet, but the section already holds the Private Relay names, because the adult content filter is always on.
            #expect(daemon.hostsText() == ExpectedHosts.idleText, "nothing blocked yet, so the hosts file holds the macOS lines and a section of only the Private Relay names")
            let reply = try daemon.send(.add, domain: "reddit.com")
            // Read at once, with no waiting: only the command path can have written it.
            let hosts = daemon.hosts()
            #expect(reply.ok)
            #expect(hosts.lines.contains("0.0.0.0 reddit.com"))
            #expect(hosts.lines.contains("0.0.0.0 i.redd.it"))
            #expect(hosts.lines.contains(":: reddit.com"))
            #expect(hosts.lines.contains(":: i.redd.it"))
            #expect(hosts.text == ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com")))
            #expect(reply.status?.blocked.map(\.domain) == ["reddit.com"])
            #expect(reply.status?.blocked.first?.hosts == ExpectedHosts.expand("reddit.com"))
            #expect(reply.status?.hostsFileHealthy == true)
            #expect(permissions(of: daemon.hostsPath) == 0o644, "03 § HostsEnforcer: the written file has mode 0644")
        }
    }

    // A change caused by a command is not tampering, so the log must not say the hosts file was repaired (03 § HostsEnforcer step 5).
    @Test func addDoesNotLogAHostsFileRepair() throws {
        try withDaemon(tick: Self.neverTick) { daemon in
            // The first pass of the daemon wrote the Private Relay names and logged a repair for it (see logCount); the add must not log another.
            let repairsAtStart = daemon.logCount(of: "hosts file repaired")
            try daemon.prepare(blocking: "reddit.com")
            #expect(daemon.logCount(of: "hosts file repaired") == repairsAtStart)
        }
    }

    // The request in the task: youtube.com and its five named hosts are written, in both address families, before the add response returns.
    @Test func addYoutubeWritesItsNamedHostsBeforeTheResponseReturns() throws {
        try withDaemon(tick: Self.neverTick) { daemon in
            try daemon.setUp()
            let reply = try daemon.send(.add, domain: "youtube.com")
            let hosts = daemon.hosts()
            #expect(reply.ok)
            for host in ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "i.ytimg.com"] {
                #expect(hosts.count(of: "0.0.0.0 \(host)") == 1, "0.0.0.0 \(host)")
                #expect(hosts.count(of: ":: \(host)") == 1, ":: \(host)")
            }
            #expect(hosts.text == ExpectedHosts.text(blocking: ExpectedHosts.expand("youtube.com")))
        }
    }

    // 01 § Commands: `add` needs a password first, and a refused add leaves the hosts file untouched.
    @Test func addBeforeSetupIsRefusedAndTheHostsFileIsUntouched() throws {
        try withDaemon { daemon in
            let reply = try daemon.send(.add, domain: "reddit.com")
            #expect(reply.ok == false)
            #expect(reply.errorCode == .notSetUp)
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
            let status = try daemon.status()
            #expect(status.blocked.isEmpty)
        }
    }

    // 03 § HostsEnforcer step 1: a missing hosts file counts as empty, and the next write creates it. Design change (01 § How Blocking Works, Adult content filter): the first write is now the daemon's own startup pass, which creates the file with a section of only the Private Relay names; the add then fills the same section.
    @Test func addCreatesTheHostsFileWhenItDoesNotExist() throws {
        try withDaemon(hosts: nil, start: false) { daemon in
            try require(!FileManager.default.fileExists(atPath: daemon.hostsPath), "the sandbox must start without a hosts file")
            try daemon.start()
            let idle = daemon.hosts()
            #expect(idle.beginCount == 1 && idle.endCount == 1, "the startup pass creates the file with the section; file now:\n\(daemon.hostsText())")
            #expect(ExpectedHosts.privateRelayHosts.allSatisfy { idle.blocks($0) })
            try daemon.prepare(blocking: "reddit.com")
            let hosts = daemon.hosts()
            #expect(hosts.blocks("reddit.com") && hosts.blocks("i.redd.it"))
            #expect(hosts.beginCount == 1 && hosts.endCount == 1)
        }
    }

    // 03 § DaemonRuntime startup step 5: blocks apply at boot, before any client connects, even if the hosts file was changed while the daemon was down. No client touches the daemon here and the tick never fires, so only the startup pass can repair the file.
    @Test func hostsFileTamperedWhileTheDaemonWasDownIsRepairedAtBootWithoutAnyClient() throws {
        try withDaemon(tick: Self.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let expected = daemon.hostsText()
            daemon.terminate()
            // The first start logged a repair too (it wrote the section), so the boot repair is the next line, not just any line (see waitForLogCount).
            let repairsBeforeRestart = daemon.logCount(of: "hosts file repaired")
            try writeText("151.101.1.140 reddit.com\n" + StandardHosts.text, to: daemon.hostsPath)
            try daemon.start(serve: false)
            let repaired = waitUntil(timeout: 3.0, interval: 0.02) { daemon.hostsText() == expected }
            #expect(repaired != nil, "the boot pass did not repair the file; now:\n\(daemon.hostsText())")
            try daemon.waitUntilServing()
            #expect(daemon.waitForLogCount(of: "hosts file repaired", atLeast: repairsBeforeRestart + 1), "03 § HostsEnforcer step 7: a change not caused by a command is logged; log:\n\(daemon.logText())")
        }
    }

    // MARK: Tampering while the daemon runs

    // One way of damaging the hosts file by hand.
    enum Tamper: CaseIterable, CustomTestStringConvertible {
        case removeWholeSection, deleteFile, emptyFile, deleteOneLine, deleteRelayNameLines, foreignLineInsideSection, changeAddress, duplicateSection, crlfLineEndings, truncateAtALineBoundary
        var testDescription: String { String(describing: self) }

        // Damages the file; `expected` is the correct text before the damage.
        func apply(to path: String, expected: String) throws {
            switch self {
            case .removeWholeSection: try writeText(StandardHosts.text, to: path)
            case .deleteFile: try FileManager.default.removeItem(atPath: path)
            case .emptyFile: try writeText("", to: path)
            case .deleteOneLine: try writeText(expected.replacingOccurrences(of: "0.0.0.0 i.redd.it\n", with: ""), to: path)
            case .deleteRelayNameLines: try writeText(expected.replacingOccurrences(of: "0.0.0.0 mask.icloud.com\n:: mask.icloud.com\n", with: ""), to: path)
            case .foreignLineInsideSection: try writeText(expected.replacingOccurrences(of: ExpectedHosts.endMarker, with: "1.2.3.4 injected.example\n" + ExpectedHosts.endMarker), to: path)
            case .changeAddress: try writeText(expected.replacingOccurrences(of: "0.0.0.0 reddit.com", with: "127.0.0.1 reddit.com"), to: path)
            case .duplicateSection: try writeText(expected + "\n" + ExpectedHosts.section(for: ["reddit.com"]), to: path)
            case .crlfLineEndings: try writeText(expected.replacingOccurrences(of: "\n", with: "\r\n"), to: path)
            case .truncateAtALineBoundary:
                // Keeps the macOS lines, the BEGIN line and about half of the host lines, cut cleanly between two lines.
                let lines = expected.components(separatedBy: "\n")
                try writeText(lines.prefix(lines.count / 2).joined(separator: "\n") + "\n", to: path)
            }
        }

        // 03 § HostsEnforcer step 7: "hosts file repaired" is logged when a pass adds missing block lines or removes bypass lines. Damage that only makes the pass take lines away (a duplicate section, a foreign line inside the section) or only changes line endings is not clearly either, so the log line is not required for those.
        var expectsRepairedLogLine: Bool {
            switch self {
            case .duplicateSection, .foreignLineInsideSection, .crlfLineEndings: return false
            default: return true
            }
        }

        // The texts the daemon may legitimately leave behind. When the whole file is gone or empty the daemon cannot know the user's macOS lines, so only the managed section comes back; whether it is preceded by one empty line is not fixed by the design (a spec gap), so both forms pass.
        func acceptableRestoredTexts(expected: String) -> [String] {
            switch self {
            case .deleteFile, .emptyFile: return [ExpectedHosts.section(for: ExpectedHosts.expand("reddit.com")), "\n" + ExpectedHosts.section(for: ExpectedHosts.expand("reddit.com"))]
            default: return [expected]
            }
        }
    }

    // 05 Integration Tests, second bullet (generalized): any hand edit of the hosts file is undone within 1 second. The file returns to exactly the correct text, or, when the user's own lines were destroyed too, to exactly the managed section.
    @Test(arguments: Tamper.allCases)
    func tamperedHostsFileIsRestoredWithinOneSecond(tamper: Tamper) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let expected = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            try #require(daemon.hostsText() == expected)
            // The first pass logged a repair too, so the repair of this tampering is the next line, not just any line (see waitForLogCount).
            let repairsBefore = daemon.logCount(of: "hosts file repaired")
            try tamper.apply(to: daemon.hostsPath, expected: expected)
            try #require(daemon.hostsText() != expected, "the tamper must change the file")
            let acceptable = tamper.acceptableRestoredTexts(expected: expected)
            let took = waitUntil(timeout: 1.0, interval: 0.01) { acceptable.contains(daemon.hostsText()) }
            #expect(took != nil, "not restored within 1 s; file now:\n\(daemon.hostsText())")
            let status = try daemon.status()
            #expect(status.hostsFileHealthy)
            if tamper.expectsRepairedLogLine { #expect(daemon.waitForLogCount(of: "hosts file repaired", atLeast: repairsBefore + 1), "log was:\n\(daemon.logText())") }
        }
    }

    // 01 § Threat Model: removing the whole section by hand is undone, and the macOS lines the user keeps are not disturbed.
    @Test func restoredHostsFileKeepsTheOriginalMacOSLines() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try writeText(StandardHosts.text, to: daemon.hostsPath)
            waitUntil(timeout: 1.0) { daemon.hosts().blocks("reddit.com") }
            #expect(daemon.hostsText().hasPrefix(StandardHosts.text))
            #expect(daemon.hosts().beginCount == 1)
        }
    }

    // 05 Integration Tests, third bullet: a line that points a blocked name at a real address is removed.
    @Test(arguments: [
        "151.101.1.140 reddit.com",
        "151.101.1.140\treddit.com",
        "151.101.1.140 REDDIT.COM",
        "151.101.1.140 www.reddit.com",
        "151.101.1.140 i.redd.it",
        "::1 reddit.com",
        "151.101.1.140 reddit.com # my own note",
        "151.101.1.140 reddit.com#note",
        "  151.101.1.140   reddit.com  ",
        "151.101.1.140 reddit.com.",
        "151.101.1.140 REDDIT.COM.",
        "151.101.1.140 reddit.com\u{0}",
        "151.101.1.140 reddit.com\u{0} ignored.example",
    ])
    func bypassLineAtTheTopIsRemoved(bypass: String) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let expected = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            // The first pass logged a repair too, so the repair of the bypass line is the next line, not just any line (see waitForLogCount).
            let repairsBefore = daemon.logCount(of: "hosts file repaired")
            try writeText(bypass + "\n" + expected, to: daemon.hostsPath)
            let took = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected }
            #expect(took != nil, "bypass line not removed within 1 s; file now:\n\(daemon.hostsText())")
            #expect(daemon.waitForLogCount(of: "hosts file repaired", atLeast: repairsBefore + 1), "03 § HostsEnforcer step 7: removing bypass lines is logged as a repair; log:\n\(daemon.logText())")
        }
    }

    // 02 § HostsFileEditor render step 2: a bypass line at the bottom of a file with no trailing newline is also removed.
    @Test func bypassLineAtTheEndWithoutTrailingNewlineIsRemoved() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let expected = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            try writeText(expected + "151.101.1.140 reddit.com", to: daemon.hostsPath)
            let took = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected }
            #expect(took != nil, "file now:\n\(daemon.hostsText())")
        }
    }

    // 02 § HostsFileEditor render step 3: a line that names a blocked host and another host keeps only the other host.
    @Test func bypassLineWithAnotherNameKeepsTheOtherName() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let blockedText = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            try writeText("151.101.1.140 reddit.com other.example\n" + blockedText, to: daemon.hostsPath)
            let expected = "151.101.1.140 other.example\n" + blockedText
            let took = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected }
            #expect(took != nil, "file now:\n\(daemon.hostsText())")
        }
    }

    // 02 § HostsFileEditor render step 3: comments that mention a blocked host, and lines for hosts that are not blocked, are left alone.
    @Test func commentsAndUnrelatedLinesAreKeptAndNotRewritten() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let blockedText = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let edited = "# reddit.com is blocked on purpose\n10.0.0.5 intranet.example\n" + blockedText
            try writeText(edited, to: daemon.hostsPath)
            let repairsBefore = daemon.logCount(of: "hosts file repaired")
            pause(0.8)
            #expect(daemon.hostsText() == edited, "a file that is already correct must not be rewritten")
            #expect(daemon.logCount(of: "hosts file repaired") == repairsBefore)
        }
    }

    // A pending unblock does not release the hosts: tampering during the wait is still undone.
    @Test func bypassLineWhileAnUnblockIsPendingIsStillRemoved() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.setDelay, password: SandboxDaemon.password, seconds: 30).requireOK()
            try daemon.send(.unblock, domain: "reddit.com", password: SandboxDaemon.password).requireOK()
            let expected = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            try writeText("151.101.1.140 reddit.com\n" + expected, to: daemon.hostsPath)
            let took = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected }
            #expect(took != nil, "file now:\n\(daemon.hostsText())")
        }
    }
}

extension BlockingTests {
    // 02 § HostsFileEditor render step 3: the editor reads a line the way the macOS resolver does, so these lines hold no blocked name and are left exactly as they were: the part after a NUL character is not read, a non-breaking space is not a field separator, other names that merely contain the blocked name stay, and comments stay.
    @Test func linesTheResolverWouldNotReadAsABlockedNameAreLeftExactlyAsTheyWere() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let blockedText = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let userLines = [
                "10.0.0.5 intranet.example\u{0} reddit.com",
                "151.101.1.140\u{A0}reddit.com",
                "151.101.1.140 xreddit.com",
                "151.101.1.140 reddit.com.evil.example",
                "# 151.101.1.140 reddit.com",
            ]
            let edited = userLines.joined(separator: "\n") + "\n" + blockedText
            try writeText(edited, to: daemon.hostsPath)
            let repairsBefore = daemon.logCount(of: "hosts file repaired")
            pause(0.8)
            #expect(daemon.hostsText() == edited, "lines with no blocked name must be left exactly as they were")
            #expect(daemon.logCount(of: "hosts file repaired") == repairsBefore)
        }
    }

    // 02 § HostsFileEditor render step 2: a user comment that looks like a BEGIN marker, far above the real section, costs only that one comment line. The user's own entries between it and the real section survive.
    @Test func aUserCommentThatLooksLikeABeginMarkerCostsOnlyThatLine() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let withFakeMarker = StandardHosts.text + "# BEGIN SiteBlock entries I added myself\n10.0.0.5 intranet.example\n\n" + ExpectedHosts.section(for: ExpectedHosts.expand("reddit.com"))
            try writeText(withFakeMarker, to: daemon.hostsPath)
            let expected = StandardHosts.text + "10.0.0.5 intranet.example\n\n" + ExpectedHosts.section(for: ExpectedHosts.expand("reddit.com"))
            let took = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected }
            #expect(took != nil, "file now:\n\(daemon.hostsText())")
        }
    }
}

extension Response {
    // Throws a TestFailure with the daemon's error sentence when the response is not ok. Returns self so calls can be chained.
    @discardableResult
    func requireOK() throws -> Response {
        try require(ok, "the daemon refused the command: \(errorCode?.rawValue ?? "?"): \(error ?? "?")")
        return self
    }
}
