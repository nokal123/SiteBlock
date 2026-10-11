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

/// Counts requests that were turned away, per user ID, and writes one summary line per user ID each minute. This keeps a flood of bad requests from filling the log with one line each. It is safe to call from any thread.
final class RejectedRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [uid_t: Int] = [:]
    private var timer: DispatchSourceTimer?
    private let log: Logger

    /// Creates a counter that writes its summary lines to the given logger. Nothing is written until `start()` or `flush()`.
    init(log: Logger) {
        self.log = log
    }

    /// Adds one rejected request from this user ID to the running count.
    func record(uid: uid_t) {
        lock.lock()
        counts[uid, default: 0] += 1
        lock.unlock()
    }

    /// Starts the timer that writes the summary lines once a minute.
    func start() {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        source.schedule(deadline: .now() + 60, repeating: 60)
        source.setEventHandler { [weak self] in self?.flush() }
        source.resume()
        lock.lock()
        timer = source
        lock.unlock()
    }

    /// Writes one summary line for each user ID that has rejected requests since the last flush, then starts counting again from zero. It also runs when the daemon is told to stop, so the last partial minute is not lost. Never writes a line when nothing was rejected.
    func flush() {
        lock.lock()
        let snapshot = counts
        counts.removeAll()
        lock.unlock()
        for (uid, count) in snapshot.sorted(by: { $0.key < $1.key }) {
            log.log("\(count) rejected \(count == 1 ? "request" : "requests") from uid \(uid) in the last minute")
        }
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
    // Keeps Chrome's mandatory URLBlocklist policy equal to the block list, for Chrome windows that never read the hosts file (see 03 § 9).
    private let chromeEnforcer: ChromePolicyEnforcer
    // Counts requests turned away by the socket server or the command handler, so the log gets a summary line per minute instead of one line per bad request.
    private let rejections: RejectedRequestCounter
    // The serial queue that owns the engine, the store and the timers.
    private let engineQueue = DispatchQueue(label: "siteblockd.engine")
    // A separate queue for launchctl calls, so a slow launchctl cannot delay ticks or commands.
    private let guardQueue = DispatchQueue(label: "siteblockd.guard")
    private var engine: Engine
    private var server: SocketServer?
    private var tickTimer: DispatchSourceTimer?
    private var guardTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    // The one clock reading that countdowns are measured from. Both the timer tick and the catch-up before each command read it, advance every countdown by the time since it, and move it to now, so no stretch of time is counted twice or skipped.
    private var lastTick = ContinuousClock.now
    private var lastSave = ContinuousClock.now
    private var lastFailedRepair: ContinuousClock.Instant?
    // Set once an uninstall has begun; from then on nothing may rewrite the hosts file or the state.
    private let uninstallStarted = LockedFlag()
    // True when the saved state had `uninstalling` set without a finished uninstall countdown; startUp logs it and saves the corrected state.
    private var ignoredUninstallFlag = false

    /// Creates the runtime: makes the state folder, loads the saved state (or a fresh one), and builds the engine. Nothing runs until `run()`.
    init(paths: Paths, policy: Policy, tickInterval: TimeInterval, log: Logger) {
        self.paths = paths
        self.policy = policy
        self.tickInterval = tickInterval
        self.log = log
        let store = StateStore(url: URL(fileURLWithPath: paths.stateFile), backupURL: URL(fileURLWithPath: paths.stateBackup))
        self.store = store
        self.enforcer = HostsEnforcer(paths: paths, log: log)
        self.chromeEnforcer = ChromePolicyEnforcer(paths: paths, log: log)
        self.rejections = RejectedRequestCounter(log: log)

        // Startup step 1: the state folder is root-only (mode 0700) because it holds the password hash.
        try? FileManager.default.createDirectory(atPath: paths.stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Startup step 2: load the saved state (from the main file, or from the backup when the main file is missing or damaged), or start from a fresh one with the policy's default delay.
        var loaded = store.load()
        // The `uninstalling` flag is only believed when the uninstall countdown has really finished. A flag with no finished countdown behind it is treated as tampering and cleared, so editing the state file cannot trigger an uninstall.
        var clearedFlag = false
        if var state = loaded, state.uninstalling, !state.hasFinishedUninstall {
            state.uninstalling = false
            loaded = state
            clearedFlag = true
        }
        self.engine = Engine(state: loaded ?? .fresh(delaySeconds: policy.defaultDelaySeconds), policy: policy)
        self.ignoredUninstallFlag = clearedFlag
        // In production only the person logged in at the screen (or root) may set the first password. Sandbox runs leave the rule off, because the test user is not tied to /dev/console.
        if !paths.isSandbox { engine.consoleUID = { DaemonRuntime.consoleOwner() } }
        if loaded == nil { log.log("no saved state found; starting fresh") }
    }

    /// The user ID of the person logged in at the screen: the owner of /dev/console, which is root (0) when nobody is logged in. If the owner cannot be read it returns 0, so the rule fails closed: only root may set up, and a read failure never opens setup to everyone.
    private static func consoleOwner() -> uid_t {
        var info = stat()
        guard stat("/dev/console", &info) == 0 else { return 0 }
        return info.st_uid
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

        // A cleared tampered flag is reported and written back to both state files right away, so the bad value does not linger on disk.
        if ignoredUninstallFlag {
            log.log("ignored uninstalling flag without a finished uninstall countdown")
            _ = saveState()
        }

        // Startup step 3: an uninstall that was interrupted (for example by a crash) is finished instead of starting normal service. Only a state with a finished uninstall countdown counts; init already cleared the flag otherwise.
        if engine.state.hasFinishedUninstall {
            log.log("state says an uninstall was in progress; finishing it")
            beginUninstall()
            return
        }

        // Startup step 4: the engine tells the runtime when the uninstall countdown ends.
        engine.onUninstall = { [unowned self] in beginUninstall() }

        // Startup step 5: enforce the hosts file and Chrome's policy at once, so blocks apply at boot before any client connects. This pass is not "caused by a command", so tampering that happened while the daemon was stopped is logged.
        let healthy = enforceBlocks(causedByCommand: false)
        engine.setHostsHealthy(healthy)
        // If the state came from the backup, or the backup does not exist yet, write both files now.
        if !store.matchesLastSave() {
            if saveState() { log.log("state file repaired") }
        }

        // Startup step 6: open the socket. Failing here is fatal; launchd restarts the daemon after its throttle interval.
        let socketServer = SocketServer(path: paths.socket, onRejected: { [rejections] uid in rejections.record(uid: uid) }) { [unowned self] request, uid in handle(request, peerUID: uid) }
        do {
            try socketServer.start()
        } catch {
            log.log("cannot start the socket server: \(error.localizedDescription)")
            exit(1)
        }
        server = socketServer
        rejections.start()

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
                rejections.flush()
                log.log("received signal \(number); exiting")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Commands

    /// Called on a client thread. It first checks any site name in the request on this thread and rejects an invalid one at once, then hops onto the engine queue and handles the request there. Rejecting here means a flood of bad names never queues behind, or in front of, real commands and ticks.
    private func handle(_ request: Request, peerUID: uid_t) -> Response {
        // Only the commands that use a site name are checked. An unblock that is also missing its password is left to the engine, which answers badRequest first, the same as for any other missing argument.
        let usesDomain = request.command == .add || request.command == .unblock || request.command == .cancelUnblock
        let missingPassword = request.command == .unblock && request.password == nil
        if usesDomain, !missingPassword, let raw = request.domain {
            do {
                _ = try DomainNormalizer.normalize(raw)
            } catch {
                rejections.record(uid: peerUID)
                return .failure(.invalidDomain, error.localizedDescription)
            }
        }
        // The engine gets the original text and normalizes it once itself. Passing the normalized name instead would run a second pass, which strips another "www." from a name typed as "www.www.example.com".
        return engineQueue.sync { process(request, peerUID: peerUID) }
    }

    /// The commands that compare a password against the stored one.
    private static let passwordCommands: Set<Command> = [.unblock, .setDelay, .changePassword, .uninstall]

    /// True when the command really compared a password, whatever the outcome. A locked-out request, a missing password setup, or a bad argument fails before any comparison, so those are not password checks. A changePassword that fails only because the new password is too weak did compare the old one, and it was right.
    private func comparedPassword(_ command: Command, _ response: Response) -> Bool {
        guard DaemonRuntime.passwordCommands.contains(command) else { return false }
        return response.ok || response.errorCode == .wrongPassword || (command == .changePassword && response.errorCode == .weakPassword)
    }

    /// Writes the log line for one finished command. Status polling is never logged, because the menu bar app asks once a second. A successful command and every password check (right or wrong) get one line each, with the command name, the user ID and the outcome. Any other rejected command is only counted, so a flood of them cannot fill the disk. Passwords and domains are never written.
    private func logOutcome(_ command: Command, _ response: Response, peerUID: uid_t) {
        if command == .status { return }
        if response.ok || comparedPassword(command, response) {
            log.log("command \(command.rawValue) from uid \(peerUID): " + (response.ok ? "ok" : "failed (\(response.errorCode?.rawValue ?? "unknown"))"))
        } else {
            rejections.record(uid: peerUID)
        }
    }

    /// Runs one command on the engine queue: first bring every countdown up to date with the clock, then apply the command, save the state if it changed, enforce the hosts file, and build the reply from the state as it is after enforcement. The block is in the hosts file before the reply is sent.
    private func process(_ request: Request, peerUID: uid_t) -> Response {
        // The countdowns are brought up to date before the command runs. Otherwise a countdown that this command starts would be charged, at the next timer tick, for the time that passed before the command existed, and would finish early.
        catchUpCountdowns()
        // After the uninstall has begun, nothing may change the block list or touch the hosts file again. A status request is read-only and still allowed.
        if uninstallStarted.isSet {
            guard request.command == .status else {
                rejections.record(uid: peerUID)
                return .failure(.internal, "SiteBlock is uninstalling and is not accepting commands.")
            }
            // The catch-up above can be the thing that finished the uninstall countdown. The reply is built straight from the engine, with no save and no enforcement pass, because a pass now would write the blocks back into a hosts file the uninstaller has just cleaned.
            return engine.handle(request, peerUID: peerUID)
        }
        let stateBefore = engine.state
        let hostsBefore = engine.hostsToWrite
        let response = engine.handle(request, peerUID: peerUID)

        // Failed commands can change state too (the wrong-password count, a lockout), so the comparison covers every outcome. A read-only command writes nothing.
        if engine.state != stateBefore { _ = saveState() }

        // Enforce after every command, even a read-only one: the pass only reads the hosts file and Chrome's policy files when nothing is wrong, and it makes the reported hosts health current.
        let blockListChanged = engine.hostsToWrite != hostsBefore
        let healthy = enforceBlocks(causedByCommand: blockListChanged)
        engine.setHostsHealthy(healthy)

        logOutcome(request.command, response, peerUID: peerUID)

        // Rebuild the snapshot so hostsFileHealthy reflects the enforcement pass that just ran, not the one before it.
        guard response.status != nil else { return response }
        return Response(ok: response.ok, error: response.error, errorCode: response.errorCode, status: engine.snapshot(hostsFileHealthy: healthy), message: response.message)
    }

    // MARK: - Enforcement

    /// Makes the hosts file and Chrome's policy files match the engine's block list: the hosts file first, then Chrome. Both always run, so a failure in one never stops the other from being repaired. Returns true only when both ended correct, and the caller passes that to the engine as `hostsFileHealthy`. `causedByCommand` is true when the block list was just changed on purpose, so the rewrite is not logged as tampering.
    private func enforceBlocks(causedByCommand: Bool) -> Bool {
        let hostsHealthy = enforcer.enforce(blockedHosts: engine.hostsToWrite, causedByCommand: causedByCommand)
        // Sites with a pending unblock stay in `blocked` until their countdown ends, so they stay in Chrome's list too.
        let chromeHealthy = chromeEnforcer.enforce(blockedSites: engine.state.blocked, causedByCommand: causedByCommand)
        return hostsHealthy && chromeHealthy
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

    /// Advances every countdown by the time since the last tick or command, and moves that "last tick" time to now. Returns true when a countdown finished and the state must be saved, the same as `Engine.tick`. Both the timer tick and the catch-up before a command use it, so they share one clock reading.
    private func advanceCountdowns(now: ContinuousClock.Instant) -> Bool {
        // The elapsed time comes from a clock the user cannot set. Negative or odd readings are clamped to 0, and a very large one to 7 days.
        let raw = seconds(now - lastTick)
        let elapsed = raw.isFinite ? min(max(raw, 0), DaemonRuntime.maxElapsedPerTick) : 0
        lastTick = now
        return engine.tick(elapsed: elapsed)
    }

    /// Runs at the start of every command, on the engine queue: advances every countdown by the time since the last tick or command, then applies whatever finished the way a timer tick would. It saves the state, and runs an enforcement pass when something finished, so a site whose wait just ended is already out of the hosts file when the command runs. It does nothing once an uninstall has begun.
    private func catchUpCountdowns() {
        if uninstallStarted.isSet { return }
        let hostsBefore = engine.hostsToWrite
        let changed = advanceCountdowns(now: ContinuousClock.now)
        // A countdown that ended inside engine.tick may have started the uninstall; nothing else may happen then.
        if uninstallStarted.isSet || !changed { return }
        _ = saveState()
        // A finished unblock changes the block list on purpose, so that rewrite is not reported as tampering.
        let blockListChanged = engine.hostsToWrite != hostsBefore
        let healthy = enforceBlocks(causedByCommand: blockListChanged)
        engine.setHostsHealthy(healthy)
    }

    /// One timer tick: advance the countdowns by the real time that passed, enforce the hosts file, undo hand edits to the state files, and save the state when needed.
    private func tick() {
        if uninstallStarted.isSet { return }
        let now = ContinuousClock.now
        let hostsBefore = engine.hostsToWrite
        let changed = advanceCountdowns(now: now)
        // When the uninstall countdown ended inside engine.tick, the uninstall has already run; nothing else may happen.
        if uninstallStarted.isSet { return }

        // A countdown that finished (a site whose wait is over) changes the block list on purpose, so that rewrite is not reported as tampering.
        let blockListChanged = engine.hostsToWrite != hostsBefore
        let healthy = enforceBlocks(causedByCommand: blockListChanged)
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

        Uninstaller.run(paths: paths, enforcer: enforcer, chromeEnforcer: chromeEnforcer, saveUninstallingState: { [self] () -> Bool in
            // The engine set `uninstalling` before calling us, or the saved state already had it; saving the engine's state records that. A failed save is reported back so the uninstaller can stop before touching anything.
            var state = engine.state
            state.uninstalling = true
            do {
                try store.save(state)
                return true
            } catch {
                log.log("could not save the uninstall marker: \(error.localizedDescription)")
                return false
            }
        }, log: log)

        // Only production gets here. The cleanup shell is running; launchd will stop this process with the last bootout.
        log.log("waiting for launchd to stop the daemon")
        DispatchQueue.global().asyncAfter(deadline: .now() + DaemonRuntime.uninstallGiveUpSeconds) { [log] in
            log.log("launchd did not stop the daemon in time; exiting so the uninstall is retried")
            exit(0)
        }
    }
}
