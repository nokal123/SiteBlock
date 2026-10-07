import Foundation
import SiteBlockCore
import Testing

// Every child process and temp folder the tests create is recorded here, so an exit hook can clean up even when a test crashes before its own cleanup runs.
enum Registry {
    private static let lock = NSLock()
    private static var pids: Set<pid_t> = []
    private static var directories: Set<String> = []
    private static var installed = false

    // Registers the exit hook once and makes a write to a closed pipe an error instead of a fatal signal.
    static func installOnce() {
        lock.lock()
        defer { lock.unlock() }
        if installed { return }
        installed = true
        signal(SIGPIPE, SIG_IGN)
        atexit { Registry.cleanUpEverything() }
    }

    // Remembers a child process id.
    static func add(pid: pid_t) { lock.lock(); pids.insert(pid); lock.unlock() }

    // Forgets a process id once the child has been reaped, so the exit hook never signals a recycled id.
    static func remove(pid: pid_t) { lock.lock(); pids.remove(pid); lock.unlock() }

    // True while the id is still recorded (the exit hook would still signal it).
    static func contains(pid: pid_t) -> Bool { lock.lock(); defer { lock.unlock() }; return pids.contains(pid) }

    // Remembers a temp folder.
    static func add(directory: String) { lock.lock(); directories.insert(directory); lock.unlock() }

    // Forgets a folder that has been deleted.
    static func remove(directory: String) { lock.lock(); directories.remove(directory); lock.unlock() }

    // Kills every recorded process and deletes every recorded folder. A folder a test left read-only is made writable first, because `removeItem` alone cannot delete the contents of a read-only folder.
    static func cleanUpEverything() {
        lock.lock()
        let leftoverPids = pids
        let leftoverDirectories = directories
        lock.unlock()
        for pid in leftoverPids { kill(pid, SIGKILL) }
        for directory in leftoverDirectories { forceRemoveTree(directory) }
    }
}

// How a child process ended.
struct ExitInfo {
    // The exit code, or the signal number when the process was killed by a signal.
    let status: Int32
    // True when a signal ended the process instead of a normal exit.
    let killedBySignal: Bool
}

// One real `siteblockd --daemon --sandbox <dir>` child process with its own temp folder. Each test makes its own, so tests can run in parallel.
final class SandboxDaemon {
    // The SiteBlock password tests use unless they pick another.
    static let password = "swordfish-77"

    // The sandbox folder, a short random name under /tmp (a Unix socket path must be under 104 bytes).
    let root: String
    // The enforcement interval passed to the daemon with --tick.
    let tickSeconds: Double
    private var process: Process?

    // Creates the sandbox folder and writes the starting hosts file (the standard macOS lines unless told otherwise, or no file when `hosts` is nil). Does not start the daemon.
    init(tick: Double = 0.2, hosts: String? = StandardHosts.text) throws {
        Registry.installOnce()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let name = String((0..<8).map { _ in alphabet.randomElement()! })
        root = "/tmp/sb-" + name
        tickSeconds = tick
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        Registry.add(directory: root)
        if let hosts { try writeText(hosts, to: hostsPath) }
    }

    // MARK: Paths (from 04-infrastructure.md § Installed Paths: Paths.sandbox puts every file under the sandbox folder)

    var hostsPath: String { root + "/hosts" }
    var stateDir: String { root + "/state" }
    var statePath: String { root + "/state/state.json" }
    var stateBackupPath: String { root + "/libexec/siteblock/state.backup.json" }
    var socketPath: String { root + "/siteblock.sock" }
    // Where the daemon's standard output and error (its log lines) are collected.
    var logPath: String { root + "/daemon.log" }

    // MARK: Process control

    // The child's process id, or nil when it was never started.
    var pid: pid_t? { process?.processIdentifier }

    // True while the child process is alive. Once the child has ended (and Foundation has collected its exit status) its id is dropped from the exit-hook registry, because the system may give that id to an unrelated process and the hook must never signal it.
    var isRunning: Bool {
        guard let child = process else { return false }
        if child.isRunning { return true }
        Registry.remove(pid: child.processIdentifier)
        return false
    }

    // Starts `siteblockd --daemon --sandbox <root> --tick <tick> --policy-fast`. With `serve` true it also waits up to 5 seconds until the daemon answers a status request.
    func start(serve: Bool = true) throws {
        // `isRunning` also drops the id of an earlier child that has ended from the exit-hook registry.
        if isRunning { throw TestFailure("the daemon is already running") }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: try Binaries.path("siteblockd"))
        child.arguments = ["--daemon", "--sandbox", root, "--tick", String(tickSeconds), "--policy-fast"]
        child.environment = ["PATH": "/usr/bin:/bin"]
        child.standardInput = FileHandle.nullDevice
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        try log.seekToEnd()
        child.standardOutput = log
        child.standardError = log
        try child.run()
        // Registered at once, before anything else can fail, so a trap in the test still gets this daemon killed by the exit hook.
        Registry.add(pid: child.processIdentifier)
        process = child
        try? log.close()
        if serve { try waitUntilServing() }
    }

    // Waits up to `timeout` seconds for the daemon to answer a status request. Throws with the daemon's log when it died or never answered.
    func waitUntilServing(timeout: Double = 5) throws {
        let probe = DaemonClient(socketPath: socketPath, timeout: 2)
        var answered = false
        waitUntil(timeout: timeout, interval: 0.025) {
            if !isRunning { return true }
            if let reply = try? probe.send(Request(command: .status)), reply.ok { answered = true }
            return answered
        }
        if !answered {
            let state = isRunning ? "never answered" : "exited with \(String(describing: waitForExit(timeout: 1)?.status))"
            throw TestFailure("the daemon \(state) within \(timeout) s. Log:\n\(logText())")
        }
    }

    // Waits up to `timeout` seconds for the child to end and reports how it ended, or nil when it is still running.
    func waitForExit(timeout: Double) -> ExitInfo? {
        guard let child = process else { return nil }
        guard waitUntil(timeout: timeout, interval: 0.01, { !child.isRunning }) != nil else { return nil }
        Registry.remove(pid: child.processIdentifier)
        return ExitInfo(status: child.terminationStatus, killedBySignal: child.terminationReason == .uncaughtSignal)
    }

    // Sends SIGTERM (the polite stop signal launchd uses) and waits up to 3 seconds; falls back to SIGKILL. Returns how it ended.
    @discardableResult
    func terminate() -> ExitInfo? {
        guard let child = process, isRunning else { return nil }
        kill(child.processIdentifier, SIGTERM)
        if let info = waitForExit(timeout: 3) { return info }
        return kill9()
    }

    // Sends SIGKILL, which no program can catch, and waits for the process to be gone. The socket file stays behind, as after a real crash.
    @discardableResult
    func kill9() -> ExitInfo? {
        guard let child = process, isRunning else { return nil }
        kill(child.processIdentifier, SIGKILL)
        return waitForExit(timeout: 3)
    }

    // Kills the child if it is still running and deletes the whole sandbox folder, including any part a test left read-only. Safe to call more than once. The child's id leaves the exit-hook registry as soon as the child is gone, whether it ended by itself earlier or was killed here, so the hook never signals a process that reused the id.
    func teardown() {
        if let child = process, child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            _ = waitForExit(timeout: 3)
        }
        _ = isRunning
        forceRemoveTree(root)
        Registry.remove(directory: root)
    }

    // MARK: Timing helpers

    // Waits a random time between 0 and one enforcement tick (at most one second), so the next command lands at a random point of the daemon's tick cycle. Returns the wait so a failure message can name it.
    @discardableResult
    func pauseToRandomTickPhase() -> Double {
        let delay = Double.random(in: 0...min(tickSeconds, 1.0))
        pause(delay)
        return delay
    }

    // Freezes the child with SIGSTOP, as a sleeping Mac or a debugger would. The daemon runs no code until `resume()`, but the wall clock and the monotonic clock keep running.
    func freeze() {
        if let pid { kill(pid, SIGSTOP) }
    }

    // Lets a frozen child run again with SIGCONT.
    func resume() {
        if let pid { kill(pid, SIGCONT) }
    }

    // MARK: Talking to the daemon

    // A client for this sandbox's socket.
    func client(timeout: Double = 10) -> DaemonClient {
        DaemonClient(socketPath: socketPath, timeout: timeout)
    }

    // Sends one command over the real socket with the real DaemonClient.
    func send(_ command: Command, domain: String? = nil, password: String? = nil, newPassword: String? = nil, seconds: Int? = nil) throws -> Response {
        try client().send(Request(command: command, domain: domain, password: password, newPassword: newPassword, seconds: seconds))
    }

    // The current status snapshot; throws when the daemon refuses or does not answer.
    func status() throws -> StatusSnapshot {
        let reply = try send(.status)
        guard reply.ok, let snapshot = reply.status else { throw TestFailure("status failed: \(reply.error ?? "no reason given")") }
        return snapshot
    }

    // Sets the first password.
    func setUp(password: String = SandboxDaemon.password) throws {
        let reply = try send(.setup, password: password)
        try require(reply.ok, "setup failed: \(reply.error ?? "?")")
    }

    // Blocks each domain and requires every add to succeed.
    func block(_ domains: String...) throws {
        for domain in domains {
            let reply = try send(.add, domain: domain)
            try require(reply.ok, "add \(domain) failed: \(reply.error ?? "?")")
        }
    }

    // Sets the password, then blocks each domain: the usual starting point of a test.
    func prepare(blocking domains: String...) throws {
        try setUp()
        for domain in domains { try block(domain) }
    }

    // Requires the sandbox's unblock delay to be the 2 seconds that 05-testing-and-operations.md assumes ("2 seconds with a delay of 2").
    func requireTwoSecondDelay() throws {
        let delay = try status().delaySeconds
        try require(delay == 2, "the test daemon's delay is \(delay) s; the design's integration tests assume a delay of 2 s under --policy-fast")
    }

    // MARK: Reading what is on disk

    // The sandbox hosts file as text (empty when it does not exist).
    func hostsText() -> String { readText(hostsPath) ?? "" }

    // The sandbox hosts file as a view.
    func hosts() -> HostsView { HostsView(readText(hostsPath)) }

    // Everything the daemon has written to its log so far.
    func logText() -> String { readText(logPath) ?? "" }

    // Waits up to `seconds` for the log to contain the text. The daemon renames a repaired file into place first and writes its log line just after, so a test that has seen the file change must give the line a moment to appear.
    func logContains(_ text: String, within seconds: Double = 1.5) -> Bool {
        waitUntil(timeout: seconds, interval: 0.02) { logText().contains(text) } != nil
    }

    // The saved state file as a JSON object, or nil when it is missing or not an object.
    func stateObject() -> NSDictionary? { readJSONObject(statePath) }

    // The names of the files in a folder (empty when it does not exist).
    func listing(of directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    }
}

// Starts a sandbox daemon, runs the body, and always kills the daemon and deletes the folder afterwards, even when the body throws or an expectation fails.
func withDaemon<T>(tick: Double = 0.2, hosts: String? = StandardHosts.text, start: Bool = true, _ body: (SandboxDaemon) throws -> T) throws -> T {
    let daemon = try SandboxDaemon(tick: tick, hosts: hosts)
    defer { daemon.teardown() }
    if start { try daemon.start() }
    return try body(daemon)
}

// How a test stops the daemon.
enum StopMethod: CaseIterable, CustomTestStringConvertible {
    // The polite stop signal launchd sends; the daemon saves its state and exits with code 0.
    case sigterm
    // The uncatchable kill (`kill -9`); the daemon gets no chance to save anything.
    case sigkill

    var testDescription: String { self == .sigterm ? "SIGTERM" : "SIGKILL" }
}

extension SandboxDaemon {
    // Stops the daemon with the given signal and waits for it to be gone.
    @discardableResult
    func stop(_ method: StopMethod) -> ExitInfo? {
        switch method {
        case .sigterm: return terminate()
        case .sigkill: return kill9()
        }
    }
}
