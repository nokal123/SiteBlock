import Foundation
import SiteBlockCore
import Testing

// The test helpers themselves: the cleanup that must work after a test left folders read-only, and the exit-hook registry that must never keep the id of a child that is gone (the system may give that id to an unrelated process, and the hook kills every id it still holds).
// Not part of the design; these checks keep the suite from leaving undeletable folders under /tmp or signalling a stranger's process.
@Suite("Test support")
struct TestSupportTests {
    // A short random folder name under /tmp.
    static func scratchName() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "/tmp/sbt-" + String((0..<8).map { _ in alphabet.randomElement()! })
    }

    // A tree with read-only folders and read-only files at several depths is deleted completely, as `chmod -R u+rwx` followed by `rm -rf` would.
    @Test(.enabled(if: geteuid() != 0))
    func forceRemoveTreeDeletesReadOnlyFoldersAndFiles() throws {
        let root = Self.scratchName()
        try FileManager.default.createDirectory(atPath: root + "/a/b/c", withIntermediateDirectories: true)
        try writeText("x", to: root + "/a/b/c/file")
        try writeText("y", to: root + "/a/file")
        try writeText("z", to: root + "/top")
        for path in [root + "/a/b/c/file", root + "/a/file", root + "/top"] { try chmodPath(path, 0o444) }
        for path in [root + "/a/b/c", root + "/a/b", root + "/a", root] { try chmodPath(path, 0o555) }
        defer { forceRemoveTree(root) }
        // The plain delete the exit hook used before cannot do this; that is what the helper is for.
        #expect(FileManager.default.fileExists(atPath: root + "/a/b/c/file"))
        forceRemoveTree(root)
        #expect(!FileManager.default.fileExists(atPath: root), "the read-only tree was not deleted")
    }

    // A symbolic link inside the tree is deleted as a link and never followed: what it points at, outside the tree, survives.
    @Test func forceRemoveTreeDoesNotFollowSymbolicLinks() throws {
        let root = Self.scratchName()
        let outside = Self.scratchName()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
        defer {
            forceRemoveTree(root)
            forceRemoveTree(outside)
        }
        try writeText("keep me", to: outside + "/precious")
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: outside)
        forceRemoveTree(root)
        #expect(!FileManager.default.fileExists(atPath: root))
        #expect(readText(outside + "/precious") == "keep me", "the helper followed a symbolic link out of the tree")
    }

    // A path that does not exist is not an error.
    @Test func forceRemoveTreeOnAMissingPathDoesNothing() {
        forceRemoveTree(Self.scratchName())
    }

    // teardown deletes a sandbox whose folder (and a read-only file inside a read-only subfolder) a test left unwritable.
    @Test(.enabled(if: geteuid() != 0))
    func teardownDeletesASandboxThatWasLeftReadOnly() throws {
        let daemon = try SandboxDaemon()
        try FileManager.default.createDirectory(atPath: daemon.root + "/sub", withIntermediateDirectories: false)
        try writeText("x", to: daemon.root + "/sub/file")
        try chmodPath(daemon.root + "/sub/file", 0o444)
        try chmodPath(daemon.root + "/sub", 0o555)
        try chmodPath(daemon.root, 0o555)
        daemon.teardown()
        #expect(!FileManager.default.fileExists(atPath: daemon.root), "a read-only sandbox was left behind")
        daemon.teardown()
    }

    // The id of a child that was killed from outside the helper (nobody called waitForExit) leaves the registry once teardown has run, so the exit hook never signals a recycled id.
    @Test func teardownDropsTheIdOfAChildThatEndedOnItsOwn() throws {
        let daemon = try SandboxDaemon()
        defer { daemon.teardown() }
        try daemon.start()
        let pid = try #require(daemon.pid)
        #expect(Registry.contains(pid: pid), "a started daemon must be registered")
        kill(pid, SIGKILL)
        let gone = waitUntil(timeout: 3.0, interval: 0.01) { kill(pid, 0) != 0 }
        try #require(gone != nil, "the killed daemon is still there")
        // Give Foundation a moment to collect the exit status.
        pause(0.2)
        daemon.teardown()
        #expect(!Registry.contains(pid: pid), "teardown left the id of a finished child in the registry")
    }

    // Asking whether the daemon is running after it has ended also drops its id, and a restart registers the new child.
    @Test func aRestartedDaemonIsRegisteredAndTheOldIdIsDropped() throws {
        let daemon = try SandboxDaemon()
        defer { daemon.teardown() }
        try daemon.start()
        let first = try #require(daemon.pid)
        daemon.kill9()
        #expect(!Registry.contains(pid: first))
        try daemon.start()
        let second = try #require(daemon.pid)
        #expect(second != first)
        #expect(Registry.contains(pid: second))
        #expect(!Registry.contains(pid: first))
    }

    // waitForLogCount must wait for the NEW line. An older copy of the same text satisfies `logContains` at once but must not satisfy a count that asks for one more; a line written later is seen as soon as it is there; a line that never comes ends the wait at the time limit.
    @Test func waitForLogCountWaitsForTheNewLineAndNotJustAnyLine() throws {
        try withDaemon(start: false) { daemon in
            let line = "hosts file repaired"
            try writeText("first pass: \(line)\n", to: daemon.logPath)
            #expect(daemon.logCount(of: line) == 1)
            #expect(daemon.logContains(line), "the older line is already there, which is why logContains cannot tell a new repair from the first one")

            // Enough copies already: answers at once.
            let immediate = Stopwatch()
            #expect(daemon.waitForLogCount(of: line, atLeast: 1, within: 2.0))
            #expect(immediate.elapsed < 1.5)

            // One more copy is wanted and none comes: the wait lasts the whole limit and says no.
            let missing = Stopwatch()
            #expect(!daemon.waitForLogCount(of: line, atLeast: 2, within: 0.4))
            #expect(missing.elapsed >= 0.35, "gave up after \(missing.elapsed) s, before the 0.4 s limit")

            // The second copy is written 0.4 s from now: the wait must not return before it, and must see it soon after. The writer is a thread of its own, because
            // a dispatch queue block can wait many seconds for a free thread while the rest of the suite keeps the shared pool busy. The wait limit is long for the same reason.
            let path = daemon.logPath
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.4)
                try? writeText("first pass: \(line)\nsecond: \(line)\n", to: path)
            }
            let late = Stopwatch()
            #expect(daemon.waitForLogCount(of: line, atLeast: 2, within: 20.0))
            #expect(late.elapsed >= 0.35, "returned after \(late.elapsed) s although the second line was written at 0.4 s")
            #expect(daemon.logCount(of: line) == 2)
        }
    }
}
