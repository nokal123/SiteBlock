import Foundation
import SiteBlockCore
import Testing

// Passwords, the saved password hash, and the daemon's log.
// Design: 05-testing-and-operations.md § Security Considerations ("The password is never logged, never written to disk in plain form"); 01-overview-and-data.md § Data Model (PasswordHash); 03-daemon-cli-app.md § DaemonRuntime ("Logging").
@Suite("Secrets and logs")
struct SecretsAndLogsTests {
    // Every regular file below a folder, as (path, bytes).
    static func allFiles(under root: String) -> [(path: String, data: Data)] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var found: [(String, Data)] = []
        for case let relative as String in walker {
            let full = root + "/" + relative
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue, let data = FileManager.default.contents(atPath: full) else { continue }
            found.append((full, data))
        }
        return found
    }

    // The first startup-free log line that contains the command name, or nil.
    static func firstLine(in lines: [String], naming name: String) -> String? {
        for line in lines where line.contains(name) && !line.contains("starting") { return line }
        return nil
    }

    // True when the bytes of `needle` appear anywhere in `data`.
    static func contains(_ data: Data, _ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    // 05 Security Considerations: passwords sent in setup, unblock (wrong and right), changePassword and setDelay appear in no file the daemon wrote: not the log, not state.json, not the backup, not the hosts file.
    @Test func noPasswordIsEverWrittenToTheLogOrToDisk() throws {
        let first = "Zq7-secret-ΔΩ✓-A"
        let wrong = "Wrong-Guess-93x-B"
        let second = "Newer-Pass-55!-C"
        let weak = "Wk-12"
        try withDaemon { daemon in
            try daemon.setUp(password: first)
            try daemon.block("reddit.com")
            _ = try daemon.send(.unblock, domain: "reddit.com", password: wrong)
            try daemon.send(.unblock, domain: "reddit.com", password: first).requireOK()
            try daemon.send(.cancelUnblock, domain: "reddit.com").requireOK()
            try daemon.send(.changePassword, password: first, newPassword: second).requireOK()
            let rejected = try daemon.send(.changePassword, password: second, newPassword: weak)
            #expect(rejected.errorCode == .weakPassword)
            _ = try daemon.send(.setDelay, password: wrong, seconds: 600)
            _ = try daemon.send(.setup, password: wrong)
            daemon.terminate()
            let files = Self.allFiles(under: daemon.root)
            try #require(files.contains { $0.path == daemon.logPath } && files.contains { $0.path == daemon.statePath }, "the scan must include the log and the state file")
            for secret in [first, wrong, second, weak] {
                for file in files { #expect(!Self.contains(file.data, secret), "\(secret) found in \(file.path)") }
            }
        }
    }

    // 01 § Data Model (PasswordHash): the saved hash is PBKDF2-SHA256 with the policy's iteration count (1000 under --policy-fast), a 16-byte random salt and a 32-byte key, both Base64; changing the password makes a new salt.
    @Test func theSavedPasswordHashHasTheDocumentedShape() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let firstHash = try #require(daemon.stateObject()?["passwordHash"] as? [String: Any])
            #expect(firstHash["algorithm"] as? String == "pbkdf2-sha256")
            #expect(firstHash["iterations"] as? Int == 1000)
            let salt = try #require(Data(base64Encoded: firstHash["salt"] as? String ?? ""), "salt is not valid Base64")
            let key = try #require(Data(base64Encoded: firstHash["hash"] as? String ?? ""), "hash is not valid Base64")
            #expect(salt.count == 16)
            #expect(key.count == 32)
            try daemon.send(.changePassword, password: SandboxDaemon.password, newPassword: "another-password-1").requireOK()
            let secondHash = try #require(daemon.stateObject()?["passwordHash"] as? [String: Any])
            #expect(secondHash["salt"] as? String != firstHash["salt"] as? String, "a new password needs a new random salt")
            #expect(secondHash["hash"] as? String != firstHash["hash"] as? String)
        }
    }

    // 03 § DaemonRuntime "Logging": log lines start with an ISO 8601 timestamp; successful commands other than status are logged by name and user ID; every password check, right or wrong, is logged. The exact wording is not fixed, so only names, the user ID and the existence of a line for the wrong password are checked.
    @Test func theLogHasTimestampedLinesAndRecordsCommandsByNameAndUserId() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.block("reddit.com")
            let before = daemon.logText().components(separatedBy: "\n").filter { !$0.isEmpty }.count
            _ = try daemon.send(.unblock, domain: "reddit.com", password: "wrong-wrong")
            let afterWrong = daemon.logText().components(separatedBy: "\n").filter { !$0.isEmpty }
            #expect(afterWrong.count > before, "a wrong password check must be logged")
            #expect(afterWrong.dropFirst(before).contains { $0.lowercased().contains("password") || $0.contains("unblock") }, "the new line should name the password check: \(afterWrong.dropFirst(before))")
            try daemon.send(.setDelay, password: SandboxDaemon.password, seconds: 60).requireOK()
            let lines = daemon.logText().components(separatedBy: "\n").filter { !$0.isEmpty }
            for line in lines {
                #expect(line.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2}) ", options: .regularExpression) != nil, "no ISO 8601 timestamp: \(line)")
            }
            for name in ["setup", "add", "setDelay"] {
                let named = Self.firstLine(in: lines, naming: name)
                #expect(named != nil, "no log line names the command \(name)")
                #expect(named?.contains(String(getuid())) == true, "the \(name) line should carry the caller's user ID \(getuid()): \(named ?? "none")")
            }
        }
    }

    // 03 § DaemonRuntime "Logging": passwords and domains are never logged. Sites that are blocked, refused or injected leave no trace of their names in the log.
    @Test func domainsAreNeverLogged() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            try daemon.block("reddit.com", "secret-site.example.org")
            for payload in ["evil.com\n0.0.0.0 bank.com", "refused-name.example", "1.2.3.4"] {
                _ = try rawExchange(try requestLine(["command": "add", "domain": payload]), socketPath: daemon.socketPath)
            }
            _ = try daemon.send(.unblock, domain: "reddit.com", password: "wrong-wrong")
            _ = try daemon.send(.cancelUnblock, domain: "never-seen.example")
            pause(0.5)
            let log = daemon.logText()
            for name in ["reddit", "secret-site", "evil.com", "bank.com", "refused-name", "never-seen", "1.2.3.4"] {
                #expect(!log.contains(name), "\(name) appears in the log:\n\(log)")
            }
        }
    }

    // 03 § DaemonRuntime "Logging": other rejected commands (invalid domain, malformed request, and commands the engine refuses without a password check) are counted per user and logged as one summary line per minute, so a flood of bad requests cannot fill the disk. A hundred refused requests of every kind must not write anything like a hundred lines.
    @Test func aFloodOfRejectedRequestsDoesNotWriteOneLogLineEach() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let before = daemon.logText().components(separatedBy: "\n").filter { !$0.isEmpty }.count
            for n in 1...20 {
                // Refused before the engine: an invalid domain, and a request that is not JSON.
                _ = try rawExchange(try requestLine(["command": "add", "domain": "1.2.3.\(n)"]), socketPath: daemon.socketPath)
                _ = try rawExchange("not json \(n)\n", socketPath: daemon.socketPath)
                // Refused by the engine with no password comparison: already blocked, nothing pending, not blocked, bad delay, already set up.
                _ = try daemon.send(.add, domain: "reddit.com")
                _ = try daemon.send(.cancelUnblock, domain: "reddit.com")
                _ = try daemon.send(.cancelUnblock, domain: "not-blocked.example")
                _ = try daemon.send(.setDelay, password: SandboxDaemon.password, seconds: 0)
            }
            pause(0.5)
            let after = daemon.logText().components(separatedBy: "\n").filter { !$0.isEmpty }.count
            #expect(after - before <= 3, "120 rejected requests wrote \(after - before) log lines")
        }
    }

    // 03 § DaemonRuntime "Logging": status is the one command that is never logged (the menu bar app polls it every second), so polling adds no log lines at all.
    @Test func statusPollingWritesNothingToTheLog() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let before = daemon.logText().components(separatedBy: "\n").filter { !$0.isEmpty }.count
            for _ in 1...20 { _ = try daemon.status() }
            let cli = try runCLI(["status"], socket: daemon.socketPath)
            #expect(cli.status == 0)
            pause(0.3)
            let after = daemon.logText().components(separatedBy: "\n").filter { !$0.isEmpty }.count
            #expect(after == before, "status requests wrote \(after - before) log lines")
        }
    }
}
