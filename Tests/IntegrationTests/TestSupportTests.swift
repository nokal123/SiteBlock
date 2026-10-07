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
}
