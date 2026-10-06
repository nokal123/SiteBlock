import Foundation

/// The fixed numbers that govern waiting periods, lockouts and password hashing. It is a struct so sandbox runs and tests can use shorter values.
public struct Policy: Sendable, Equatable {
    /// The unblock delay a fresh install starts with.
    public var defaultDelaySeconds: Int
    /// The shortest delay that setDelay accepts.
    public var minDelaySeconds: Int
    /// The longest delay that setDelay accepts.
    public var maxDelaySeconds: Int
    /// How long a forgotten-password reset waits.
    public var recoverySeconds: Int
    /// How long password checks stay locked after too many wrong passwords.
    public var lockoutSeconds: Int
    /// How many wrong passwords trigger a lockout.
    public var maxFailedAttempts: Int
    /// How many PBKDF2 rounds new password hashes use.
    public var pbkdf2Iterations: Int

    /// Creates a policy from every value.
    public init(defaultDelaySeconds: Int, minDelaySeconds: Int, maxDelaySeconds: Int, recoverySeconds: Int, lockoutSeconds: Int, maxFailedAttempts: Int, pbkdf2Iterations: Int) {
        self.defaultDelaySeconds = defaultDelaySeconds
        self.minDelaySeconds = minDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.recoverySeconds = recoverySeconds
        self.lockoutSeconds = lockoutSeconds
        self.maxFailedAttempts = maxFailedAttempts
        self.pbkdf2Iterations = pbkdf2Iterations
    }

    /// The values the installed service always uses: 30 minute delay, 60 second to 7 day range, 48 hour recovery, 15 minute lockout after 5 wrong passwords.
    public static let production = Policy(defaultDelaySeconds: 1800, minDelaySeconds: 60, maxDelaySeconds: 604_800, recoverySeconds: 172_800, lockoutSeconds: 900, maxFailedAttempts: 5, pbkdf2Iterations: 210_000)

    /// Short waits for sandbox runs and tests only.
    public static let fastForTests = Policy(defaultDelaySeconds: 2, minDelaySeconds: 1, maxDelaySeconds: 604_800, recoverySeconds: 3, lockoutSeconds: 2, maxFailedAttempts: 5, pbkdf2Iterations: 1000)
}

/// The whole policy of SiteBlock in one class: it holds the state, applies commands, advances countdowns, and reports what the hosts file should contain. It does no file or socket work, so tests can drive it with fake time.
public final class Engine {
    /// A command that cannot continue; carries the failure response to send back.
    private struct Rejection: Error {
        let response: Response
    }

    /// The current persisted state; the runtime saves it after every command and after ticks that change it.
    public private(set) var state: PersistedState
    /// The fixed numbers this engine applies.
    public let policy: Policy
    /// Called once when the uninstall countdown finishes.
    public var onUninstall: (() -> Void)?
    // The result of the last hosts file enforcement pass, reported in every status. It starts true because the runtime enforces once at startup and then sets it.
    private var lastHostsHealthy = true

    /// Creates an engine around loaded (or fresh) state and a policy.
    public init(state: PersistedState, policy: Policy) {
        self.state = state
        self.policy = policy
    }

    /// Every host of every blocked site, sorted, without duplicates. Sites with a pending unblock are included, because they stay blocked until the countdown ends.
    public var blockedHosts: [String] {
        Array(Set(state.blocked.flatMap { $0.hosts })).sorted()
    }

    /// Records whether the last hosts file enforcement pass left the file correct, so later status responses can report it.
    public func setHostsHealthy(_ healthy: Bool) {
        lastHostsHealthy = healthy
    }

    /// Builds the status picture sent to clients.
    public func snapshot(hostsFileHealthy: Bool) -> StatusSnapshot {
        StatusSnapshot(
            version: siteBlockVersion,
            passwordSet: state.passwordHash != nil,
            blocked: state.blocked.map { BlockedSiteStatus(domain: $0.domain, hosts: $0.hosts, unblockSecondsRemaining: $0.pendingUnblock?.displaySeconds) },
            delaySeconds: state.delaySeconds,
            pendingDelay: state.pendingDelayChange.map { PendingDelayStatus(newDelaySeconds: $0.newDelaySeconds, secondsRemaining: $0.countdown.displaySeconds) },
            uninstallSecondsRemaining: state.pendingUninstall?.displaySeconds,
            recoverySecondsRemaining: state.recovery?.displaySeconds,
            lockoutSecondsRemaining: state.lockout?.displaySeconds,
            hostsFileHealthy: hostsFileHealthy
        )
    }

    // MARK: - Commands

    /// Runs one command and always returns a response; it never throws. Every successful response carries the current status.
    public func handle(_ request: Request, peerUID: uid_t) -> Response {
        do {
            switch request.command {
            case .status: return success(nil)
            case .setup: return try setup(request)
            case .add: return try add(request)
            case .unblock: return try unblock(request)
            case .cancelUnblock: return try cancelUnblock(request)
            case .setDelay: return try setDelay(request)
            case .cancelDelayChange: return try cancelDelayChange()
            case .changePassword: return try changePassword(request)
            case .uninstall: return try uninstall(request)
            case .cancelUninstall: return try cancelUninstall()
            case .recoveryStart: return try recoveryStart(peerUID: peerUID)
            case .recoveryCancel: return try recoveryCancel()
            }
        } catch let rejection as Rejection {
            return rejection.response
        } catch {
            return .failure(.internal, "Something went wrong inside SiteBlock: \(error.localizedDescription)")
        }
    }

    /// Wraps a confirmation message together with the current status.
    private func success(_ message: String?) -> Response {
        .success(status: snapshot(hostsFileHealthy: lastHostsHealthy), message: message)
    }

    /// Builds the error that makes handle return a failure response.
    private func reject(_ code: ErrorCode, _ message: String) -> Rejection {
        Rejection(response: .failure(code, message))
    }

    /// Returns a required argument, or rejects the request with badRequest when it is missing.
    private func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw reject(.badRequest, "The request is missing '\(name)'.") }
        return value
    }

    /// Turns the typed site name into its canonical form, or rejects with invalidDomain and the normalizer's sentence.
    private func normalized(_ raw: String) throws -> String {
        do {
            return try DomainNormalizer.normalize(raw)
        } catch {
            throw reject(.invalidDomain, error.localizedDescription)
        }
    }

    /// Describes a wait in the most useful unit: whole minutes (rounded up) for a minute or more, otherwise seconds.
    private func waitText(_ seconds: Int) -> String {
        if seconds >= 60 {
            let minutes = (seconds + 59) / 60
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        let clean = max(1, seconds)
        return "\(clean) \(clean == 1 ? "second" : "seconds")"
    }

    /// The password rule shared by every command that takes a password. Returns a failure response, or nil when the password is right.
    private func checkPassword(_ password: String) -> Response? {
        // 1. A running lockout refuses without looking at the password at all, so a script cannot keep guessing during it.
        if let lockout = state.lockout {
            if !lockout.isFinished { return .failure(.lockedOut, "Too many wrong passwords. Password checks are locked for another \(waitText(lockout.displaySeconds)).") }
            // The lockout already ended but the next tick has not cleared it yet.
            state.lockout = nil
        }
        // 2. Without a password there is nothing to check against.
        guard let stored = state.passwordHash else { return .failure(.notSetUp, "No password has been set yet. Set one first.") }
        // 3. A wrong password counts toward the lockout.
        if !PasswordHasher.verify(password: password, against: stored) {
            state.failedAttempts += 1
            if state.failedAttempts >= policy.maxFailedAttempts {
                state.lockout = Countdown(seconds: Double(policy.lockoutSeconds))
                state.failedAttempts = 0
                return .failure(.wrongPassword, "Wrong password. Too many wrong passwords, so password checks are locked for \(waitText(policy.lockoutSeconds)).")
            }
            let left = policy.maxFailedAttempts - state.failedAttempts
            return .failure(.wrongPassword, "Wrong password. \(left) \(left == 1 ? "try" : "tries") left before password checks are locked for \(waitText(policy.lockoutSeconds)).")
        }
        // 4. A right password clears the wrong-password count.
        state.failedAttempts = 0
        return nil
    }

    /// Sets the first password; fails when one already exists or the new one is too weak.
    private func setup(_ request: Request) throws -> Response {
        let password = try require(request.password, "password")
        if state.passwordHash != nil { throw reject(.alreadySetUp, "A password is already set.") }
        state.passwordHash = try makeHash(for: password)
        return success("Password set.")
    }

    /// Validates a new password and hashes it, rejecting with weakPassword or internal.
    private func makeHash(for password: String) throws -> PasswordHash {
        do {
            try PasswordHasher.validateNew(password)
            return try PasswordHasher.make(password: password, iterations: policy.pbkdf2Iterations)
        } catch let error as PasswordError {
            switch error {
            case .tooShort, .whitespaceOnly: throw reject(.weakPassword, error.localizedDescription)
            case .randomFailed, .derivationFailed: throw reject(.internal, error.localizedDescription)
            }
        }
    }

    /// Blocks a site at once. If the site is already blocked with an unblock pending, it cancels that unblock instead.
    private func add(_ request: Request) throws -> Response {
        let raw = try require(request.domain, "domain")
        let domain = try normalized(raw)
        if let index = state.blocked.firstIndex(where: { $0.domain == domain }) {
            // Re-adding a site that is waiting to unblock is a way to say "keep it blocked".
            guard state.blocked[index].pendingUnblock != nil else { throw reject(.alreadyBlocked, "\(domain) is already blocked.") }
            state.blocked[index].pendingUnblock = nil
            return success("Unblock cancelled; \(domain) stays blocked.")
        }
        // Every block must be undoable later, so blocking needs a password to exist. The check comes after the existing-site case so cancelling a pending unblock never needs one.
        guard state.passwordHash != nil else { throw reject(.notSetUp, "Set a password before blocking sites, so every block can be undone later.") }
        state.blocked.append(BlockedSite(domain: domain, hosts: DomainExpander.expand(domain)))
        return success("\(domain) is now blocked.")
    }

    /// Starts the unblock countdown for a site after the password check. A second request keeps the running countdown rather than restarting it.
    private func unblock(_ request: Request) throws -> Response {
        let raw = try require(request.domain, "domain")
        let password = try require(request.password, "password")
        let domain = try normalized(raw)
        guard let index = state.blocked.firstIndex(where: { $0.domain == domain }) else { throw reject(.notBlocked, "\(domain) is not blocked.") }
        if let denied = checkPassword(password) { return denied }
        if let existing = state.blocked[index].pendingUnblock {
            return success("\(domain) is already waiting to unblock, in \(Formatting.duration(existing.displaySeconds)). You can cancel any time before then.")
        }
        state.blocked[index].pendingUnblock = Countdown(seconds: Double(state.delaySeconds))
        return success("\(domain) will unblock in \(Formatting.duration(state.delaySeconds)). You can cancel any time before then.")
    }

    /// Stops a pending unblock; needs no password because it makes the Mac stricter.
    private func cancelUnblock(_ request: Request) throws -> Response {
        let raw = try require(request.domain, "domain")
        let domain = try normalized(raw)
        guard let index = state.blocked.firstIndex(where: { $0.domain == domain }) else { throw reject(.notBlocked, "\(domain) is not blocked.") }
        guard state.blocked[index].pendingUnblock != nil else { throw reject(.nothingPending, "\(domain) has no unblock waiting.") }
        state.blocked[index].pendingUnblock = nil
        return success("Unblock cancelled; \(domain) stays blocked.")
    }

    /// Changes the unblock delay. A longer (or equal) delay applies at once; a shorter one has to wait out the current delay first.
    private func setDelay(_ request: Request) throws -> Response {
        let seconds = try require(request.seconds, "seconds")
        let password = try require(request.password, "password")
        // The range check comes before the password check, so a malformed request never costs a password attempt.
        guard seconds >= policy.minDelaySeconds, seconds <= policy.maxDelaySeconds else {
            throw reject(.invalidDelay, "The delay must be between \(Formatting.duration(policy.minDelaySeconds)) and \(Formatting.duration(policy.maxDelaySeconds)).")
        }
        if let denied = checkPassword(password) { return denied }
        if seconds >= state.delaySeconds {
            state.delaySeconds = seconds
            state.pendingDelayChange = nil
            return success("The unblock delay is now \(Formatting.duration(seconds)).")
        }
        state.pendingDelayChange = PendingDelayChange(newDelaySeconds: seconds, countdown: Countdown(seconds: Double(state.delaySeconds)))
        return success("The unblock delay will change to \(Formatting.duration(seconds)) in \(Formatting.duration(state.delaySeconds)). You can cancel any time before then.")
    }

    /// Drops a pending shorter delay; needs no password because it keeps the longer delay.
    private func cancelDelayChange() throws -> Response {
        guard state.pendingDelayChange != nil else { throw reject(.nothingPending, "No delay change is waiting.") }
        state.pendingDelayChange = nil
        return success("Delay change cancelled.")
    }

    /// Replaces the password at once after checking the old one and validating the new one.
    private func changePassword(_ request: Request) throws -> Response {
        let password = try require(request.password, "password")
        let newPassword = try require(request.newPassword, "newPassword")
        if let denied = checkPassword(password) { return denied }
        state.passwordHash = try makeHash(for: newPassword)
        return success("Password changed.")
    }

    /// Starts the uninstall countdown (as long as the current delay) after the password check, unless one is already running.
    private func uninstall(_ request: Request) throws -> Response {
        let password = try require(request.password, "password")
        if let denied = checkPassword(password) { return denied }
        if let existing = state.pendingUninstall { return success("Uninstall is already waiting, in \(Formatting.duration(existing.displaySeconds)). You can cancel any time before then.") }
        state.pendingUninstall = Countdown(seconds: Double(state.delaySeconds))
        return success("SiteBlock will uninstall in \(Formatting.duration(state.delaySeconds)). You can cancel any time before then.")
    }

    /// Stops a pending uninstall; needs no password. Once the countdown has finished and the uninstall has started, it can no longer be cancelled.
    private func cancelUninstall() throws -> Response {
        guard state.pendingUninstall != nil, !state.uninstalling else { throw reject(.nothingPending, "No uninstall is waiting.") }
        state.pendingUninstall = nil
        return success("Uninstall cancelled.")
    }

    /// Starts the forgotten-password reset countdown. Only a process running as root may start it, and only when there is a password to reset.
    private func recoveryStart(peerUID: uid_t) throws -> Response {
        guard peerUID == 0 else { throw reject(.notRoot, "Password recovery can only be started by the administrator (run it with sudo).") }
        guard state.passwordHash != nil else { throw reject(.notSetUp, "No password has been set, so there is nothing to recover.") }
        if let existing = state.recovery { return success("Password recovery is already running, with \(Formatting.duration(existing.displaySeconds)) left.") }
        state.recovery = Countdown(seconds: Double(policy.recoverySeconds))
        return success("Password recovery started. The password will be cleared in \(Formatting.duration(policy.recoverySeconds)). Blocked sites stay blocked.")
    }

    /// Stops a running password recovery; needs no password.
    private func recoveryCancel() throws -> Response {
        guard state.recovery != nil else { throw reject(.nothingPending, "No password recovery is running.") }
        state.recovery = nil
        return success("Password recovery cancelled.")
    }

    // MARK: - Time

    /// Advances every countdown by the elapsed seconds and applies the ones that finished. Returns true when something finished, meaning the state must be saved now. Negative, NaN or infinite input changes nothing.
    public func tick(elapsed: Double) -> Bool {
        guard elapsed.isFinite, elapsed > 0 else { return false }
        for index in state.blocked.indices { state.blocked[index].pendingUnblock?.advance(by: elapsed) }
        state.pendingDelayChange?.countdown.advance(by: elapsed)
        state.pendingUninstall?.advance(by: elapsed)
        state.recovery?.advance(by: elapsed)
        state.lockout?.advance(by: elapsed)

        // The order below matters only in that every finished countdown is applied; sites go first so the hosts file loses them on the next pass.
        var changed = false
        let siteCount = state.blocked.count
        state.blocked.removeAll { $0.pendingUnblock?.isFinished == true }
        if state.blocked.count != siteCount { changed = true }

        if let change = state.pendingDelayChange, change.countdown.isFinished {
            state.delaySeconds = change.newDelaySeconds
            state.pendingDelayChange = nil
            changed = true
        }
        if let lockout = state.lockout, lockout.isFinished {
            state.lockout = nil
            changed = true
        }
        if let recovery = state.recovery, recovery.isFinished {
            // A finished recovery clears the password (so setup works again) but leaves every block in place.
            state.passwordHash = nil
            state.failedAttempts = 0
            state.lockout = nil
            state.recovery = nil
            changed = true
        }
        // The uninstalling flag guards against calling onUninstall again on every later tick, so it fires exactly once.
        if let uninstall = state.pendingUninstall, uninstall.isFinished, !state.uninstalling {
            state.uninstalling = true
            changed = true
            onUninstall?()
        }
        return changed
    }
}
