import Foundation
import SiteBlockCore

/// A true/false value that several threads can read and set safely.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// True once the flag has been set.
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Sets the flag and returns true if this call was the one that set it (false when it was already set).
    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

/// Connects the policy engine to the outside world: the socket, the hosts file, the state files, the clock and the watchdog. Every touch of the engine happens on one serial queue, so a command and a timer tick can never run at the same time.
final class DaemonRuntime {
    // The longest stretch of time one tick may count. The clock used cannot be set by the user and keeps running while the Mac sleeps, so a long sleep must count; the cap is 7 days only to stop an absurd reading from finishing every countdown at once.
    private static let maxElapsedPerTick = 604_800.0
    // The state is saved at least this often while any countdown is running, so a crash loses at most this much progress.
    private static let saveInterval = Duration.seconds(15)
    // How often the watchdog is checked in production.
    private static let guardIntervalSeconds = 5.0
    // After a failed attempt to repair the state files, wait this long before trying again, so a full disk does not fill the log.
    private static let repairRetryInterval = Duration.seconds(30)
    // If an uninstall started but launchd has not stopped the daemon after this long, exit so launchd restarts it and the uninstall is retried.
    private static let uninstallGiveUpSeconds = 120.0

    private let paths: Paths
    private let policy: Policy
    private let tickInterval: TimeInterval
    private let log: Logger
    private let store: StateStore
    private let enforcer: HostsEnforcer
    // The serial queue that owns the engine, the store and the timers.
    private let engineQueue = DispatchQueue(label: "siteblockd.engine")
    // A separate queue for launchctl calls, so a slow launchctl cannot delay ticks or commands.
    private let guardQueue = DispatchQueue(label: "siteblockd.guard")
    private var engine: Engine
    private var server: SocketServer?
    private var tickTimer: DispatchSourceTimer?
    private var guardTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lastTick = ContinuousClock.now
    private var lastSave = ContinuousClock.now
    private var lastFailedRepair: ContinuousClock.Instant?
    // Set once an uninstall has begun; from then on nothing may rewrite the hosts file or the state.
    private let uninstallStarted = LockedFlag()

    /// Creates the runtime: makes the state folder, loads the saved state (or a fresh one), and builds the engine. Nothing runs until `run()`.
    init(paths: Paths, policy: Policy, tickInterval: TimeInterval, log: Logger) {
        self.paths = paths
        self.policy = policy
        self.tickInterval = tickInterval
        self.log = log
        let store = StateStore(url: URL(fileURLWithPath: paths.stateFile), backupURL: URL(fileURLWithPath: paths.stateBackup))
        self.store = store
        self.enforcer = HostsEnforcer(paths: paths, log: log)

        // Startup step 1: the state folder is root-only (mode 0700) because it holds the password hash.
        try? FileManager.default.createDirectory(atPath: paths.stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Startup step 2: load the saved state (from the main file, or from the backup when the main file is missing or damaged), or start from a fresh one with the policy's default delay.
        let loaded = store.load()
        self.engine = Engine(state: loaded ?? .fresh(delaySeconds: policy.defaultDelaySeconds), policy: policy)
        if loaded == nil { log.log("no saved state found; starting fresh") }
    }

    /// Runs the startup steps in order and then keeps running forever. Never returns.
    func run() -> Never {
        installSignalHandlers()
        // Startup runs on the engine queue like everything else that touches the engine, so a signal that arrives during startup cannot overlap with it.
        engineQueue.sync { startUp() }
        dispatchMain()
    }

    /// The startup steps after loading the state (steps 1 and 2 happened in init). Must be called on the engine queue.
    private func startUp() {
        log.log("siteblockd \(siteBlockVersion) starting (\(paths.isSandbox ? "sandbox" : "production"), tick \(tickInterval)s, blocked sites: \(engine.state.blocked.count))")

        // Startup step 3: an uninstall that was interrupted (for example by a crash) is finished instead of starting normal service.
        if engine.state.uninstalling {
            log.log("state says an uninstall was in progress; finishing it")
            beginUninstall()
            return
        }

        // Startup step 4: the engine tells the runtime when the uninstall countdown ends.
        engine.onUninstall = { [unowned self] in beginUninstall() }

        // Startup step 5: enforce the hosts file at once, so blocks apply at boot before any client connects. This pass is not "caused by a command", so tampering that happened while the daemon was stopped is logged.
        let healthy = enforcer.enforce(blockedHosts: engine.blockedHosts, causedByCommand: false)
        engine.setHostsHealthy(healthy)
        // If the state came from the backup, or the backup does not exist yet, write both files now.
        if !store.matchesLastSave() {
            if saveState() { log.log("state file repaired") }
        }

        // Startup step 6: open the socket. Failing here is fatal; launchd restarts the daemon after its throttle interval.
        let socketServer = SocketServer(path: paths.socket) { [unowned self] request, uid in handle(request, peerUID: uid) }
        do {
            try socketServer.start()
        } catch {
            log.log("cannot start the socket server: \(error.localizedDescription)")
            exit(1)
        }
        server = socketServer

        // Startup step 7: start the tick timer on the engine queue.
        lastTick = ContinuousClock.now
        lastSave = ContinuousClock.now
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [unowned self] in tick() }
        timer.resume()
        tickTimer = timer

        // In production the daemon also keeps the watchdog loaded. This is a separate timer on its own queue; sandbox runs skip it entirely.
        if !paths.isSandbox { startGuardTimer() }

        log.log("siteblockd ready; socket at \(paths.socket)")
    }

    /// Starts the repeating check that keeps the watchdog job loaded (production only).
    private func startGuardTimer() {
        let timer = DispatchSource.makeTimerSource(queue: guardQueue)
        timer.schedule(deadline: .now() + 1, repeating: DaemonRuntime.guardIntervalSeconds)
        timer.setEventHandler { [paths, log, uninstallStarted] in
            // Once an uninstall begins, reloading the watchdog would fight the uninstall.
            if !uninstallStarted.isSet { LaunchdGuard.ensureLoaded(.watchdog, paths: paths, log: log) }
        }
        timer.resume()
        guardTimer = timer
    }

    /// Makes SIGTERM and SIGINT save the state and exit with code 0. launchd restarts the daemon afterwards because of KeepAlive. The default handlers are switched off first so only these sources react.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: engineQueue)
            source.setEventHandler { [unowned self] in
                // During an uninstall the state folder is about to be deleted, so saving would only bring it back.
                if !uninstallStarted.isSet { _ = saveState() }
                server?.stop()
                log.log("received signal \(number); exiting")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Commands

    /// Called on a client thread: hops onto the engine queue and handles the request there.
    private func handle(_ request: Request, peerUID: uid_t) -> Response {
        engineQueue.sync { process(request, peerUID: peerUID) }
    }

    /// Runs one command on the engine queue: apply it, save the state if it changed, enforce the hosts file, and build the reply from the state as it is after enforcement. The block is in the hosts file before the reply is sent.
    private func process(_ request: Request, peerUID: uid_t) -> Response {
        // After the uninstall has begun, nothing may change the block list or touch the hosts file again. A status request is read-only and still allowed.
        if uninstallStarted.isSet && request.command != .status {
            return .failure(.internal, "SiteBlock is uninstalling and is not accepting commands.")
        }
        let stateBefore = engine.state
        let hostsBefore = engine.blockedHosts
        let response = engine.handle(request, peerUID: peerUID)

        // Failed commands can change state too (the wrong-password count, a lockout), so the comparison covers every outcome. A read-only command writes nothing.
        if engine.state != stateBefore { _ = saveState() }

        // Enforce after every command, even a read-only one: the pass costs one file read when nothing is wrong, and it makes the reported hosts health current.
        let blockListChanged = engine.blockedHosts != hostsBefore
        let healthy = enforcer.enforce(blockedHosts: engine.blockedHosts, causedByCommand: blockListChanged)
        engine.setHostsHealthy(healthy)

        // Passwords are never logged, only the command name, who asked and the outcome. Status polling is not logged, because the menu bar app asks once a second.
        if request.command != .status {
            log.log("command \(request.command.rawValue) from uid \(peerUID): " + (response.ok ? "ok" : "failed (\(response.errorCode?.rawValue ?? "unknown"))"))
        }

        // Rebuild the snapshot so hostsFileHealthy reflects the enforcement pass that just ran, not the one before it.
        guard response.status != nil else { return response }
        return Response(ok: response.ok, error: response.error, errorCode: response.errorCode, status: engine.snapshot(hostsFileHealthy: healthy), message: response.message)
    }

    // MARK: - Tick

    /// True when any countdown is running, which means the state must be saved regularly.
    private var anyCountdownRunning: Bool {
        let state = engine.state
        return state.blocked.contains { $0.pendingUnblock != nil } || state.pendingDelayChange != nil || state.pendingUninstall != nil || state.recovery != nil || state.lockout != nil
    }

    /// Turns a Duration into seconds as a Double.
    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// One timer tick: advance the countdowns by the real time that passed, enforce the hosts file, undo hand edits to the state files, and save the state when needed.
    private func tick() {
        if uninstallStarted.isSet { return }
        let now = ContinuousClock.now
        // The elapsed time comes from a clock the user cannot set. Negative or odd readings are clamped to 0, and a very large one to 7 days.
        let raw = seconds(now - lastTick)
        let elapsed = raw.isFinite ? min(max(raw, 0), DaemonRuntime.maxElapsedPerTick) : 0
        lastTick = now

        let hostsBefore = engine.blockedHosts
        let changed = engine.tick(elapsed: elapsed)
        // When the uninstall countdown ended inside engine.tick, the uninstall has already run; nothing else may happen.
        if uninstallStarted.isSet { return }

        // A countdown that finished (a site whose wait is over) changes the block list on purpose, so that rewrite is not reported as tampering.
        let blockListChanged = engine.blockedHosts != hostsBefore
        let healthy = enforcer.enforce(blockedHosts: engine.blockedHosts, causedByCommand: blockListChanged)
        engine.setHostsHealthy(healthy)

        // The state files must hold exactly what was last written. This is checked before any save below, so a hand edit is logged rather than silently overwritten by a routine save.
        let filesTampered = !store.matchesLastSave()
        let mayRepair = lastFailedRepair.map { now - $0 >= DaemonRuntime.repairRetryInterval } ?? true
        if filesTampered && mayRepair {
            // While the daemon runs, its memory is the source of truth, so the files are rewritten from it.
            if saveState() {
                lastFailedRepair = nil
                log.log("state file repaired")
            } else {
                lastFailedRepair = now
            }
        } else if changed || (anyCountdownRunning && now - lastSave >= DaemonRuntime.saveInterval) {
            _ = saveState()
        }
    }

    /// Writes the engine's state to the state files. Returns false (after logging why) when it fails; the daemon keeps running on its in-memory state.
    private func saveState() -> Bool {
        do {
            try store.save(engine.state)
            lastSave = ContinuousClock.now
            return true
        } catch {
            log.log("could not save state: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Uninstall

    /// Starts the uninstall on the engine queue: stops the timers and the socket so nothing can rewrite the hosts file, then runs the uninstaller. In sandbox mode the uninstaller ends the process; in production this returns and the daemon waits for launchd to stop it.
    private func beginUninstall() {
        guard uninstallStarted.setOnce() else { return }
        log.log("uninstall starting")
        tickTimer?.cancel()
        guardTimer?.cancel()
        // Wait for a guard run that is already in progress, so it cannot reload the watchdog after the plists are deleted.
        guardQueue.sync {}
        server?.stop()

        Uninstaller.run(paths: paths, enforcer: enforcer, saveUninstallingState: { [self] in
            // The engine set `uninstalling` before calling us, or the saved state already had it; saving the engine's state records that.
            var state = engine.state
            state.uninstalling = true
            do { try store.save(state) } catch { log.log("could not save the uninstall marker: \(error.localizedDescription)") }
        }, log: log)

        // Only production gets here. The cleanup shell is running; launchd will stop this process with the last bootout.
        log.log("waiting for launchd to stop the daemon")
        DispatchQueue.global().asyncAfter(deadline: .now() + DaemonRuntime.uninstallGiveUpSeconds) { [log] in
            log.log("launchd did not stop the daemon in time; exiting so the uninstall is retried")
            exit(0)
        }
    }
}
