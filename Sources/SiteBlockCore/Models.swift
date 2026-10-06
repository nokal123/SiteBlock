import Foundation

/// The version string the daemon reports and the CLI prints.
public let siteBlockVersion = "1.0.0"

/// A timer that stores the time left rather than a finish time. A finish time would be compared with the wall clock, which the user can change.
public struct Countdown: Codable, Equatable, Sendable {
    /// Seconds left; never below 0.
    public var remainingSeconds: Double
    /// The length the countdown started with, for progress display.
    public var totalSeconds: Double

    /// Creates a countdown with both the remaining and the total time set to the given length; a negative or non-finite length becomes 0.
    public init(seconds: Double) {
        let clean = seconds.isFinite ? max(0, seconds) : 0
        self.remainingSeconds = clean
        self.totalSeconds = clean
    }

    /// Creates a countdown from stored values (used when decoding saved state).
    public init(remainingSeconds: Double, totalSeconds: Double) {
        self.remainingSeconds = remainingSeconds
        self.totalSeconds = totalSeconds
    }

    /// Subtracts real elapsed time and stops at 0. Negative or non-finite input is ignored, so a bad clock reading can neither add time nor finish a countdown early.
    public mutating func advance(by elapsed: Double) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        let left = remainingSeconds - elapsed
        // Anything under a nanosecond is rounding noise from adding up many small ticks (2.0 - 1.9 - 0.1 is not exactly 0), not real time, so it counts as finished.
        remainingSeconds = left < 1e-9 ? 0 : left
    }

    /// True once no time is left.
    public var isFinished: Bool { remainingSeconds <= 0 }

    /// The remaining time rounded up to whole seconds, so a running countdown never shows 0.
    public var displaySeconds: Int {
        guard remainingSeconds.isFinite, remainingSeconds > 0 else { return 0 }
        // The upper bound keeps the Int conversion safe for absurd stored values.
        return Int(min(remainingSeconds, 1e12).rounded(.up))
    }
}

/// The stored fingerprint of the SiteBlock password.
public struct PasswordHash: Codable, Equatable, Sendable {
    /// Always "pbkdf2-sha256".
    public var algorithm: String
    /// How many times the hashing is repeated (210000 in production).
    public var iterations: Int
    /// The random salt, Base64-encoded.
    public var salt: String
    /// The derived key, Base64-encoded.
    public var hash: String

    /// Creates a password hash record from its four stored fields.
    public init(algorithm: String, iterations: Int, salt: String, hash: String) {
        self.algorithm = algorithm
        self.iterations = iterations
        self.salt = salt
        self.hash = hash
    }
}

/// One blocked site: the name the user asked for, every host name written to the hosts file for it, and an optional unblock that is waiting out its delay.
public struct BlockedSite: Codable, Equatable, Sendable {
    /// The normalized base name, for example reddit.com.
    public var domain: String
    /// The full expanded host list, sorted and without duplicates.
    public var hosts: [String]
    /// Set when an unblock was approved; when it reaches zero the site is removed.
    public var pendingUnblock: Countdown?

    /// Creates a blocked site record.
    public init(domain: String, hosts: [String], pendingUnblock: Countdown? = nil) {
        self.domain = domain
        self.hosts = hosts
        self.pendingUnblock = pendingUnblock
    }
}

/// A requested shorter unblock delay that has not taken effect yet.
public struct PendingDelayChange: Codable, Equatable, Sendable {
    /// The shorter delay that will apply when the countdown ends.
    public var newDelaySeconds: Int
    /// Time left before the new delay applies.
    public var countdown: Countdown

    /// Creates a pending delay change.
    public init(newDelaySeconds: Int, countdown: Countdown) {
        self.newDelaySeconds = newDelaySeconds
        self.countdown = countdown
    }
}

/// Everything SiteBlock remembers between runs; stored as one JSON file.
public struct PersistedState: Codable, Equatable, Sendable {
    /// The schema version this code writes.
    public static let currentVersion = 1

    /// Schema version of the stored file.
    public var version: Int
    /// The password fingerprint, or nil before the first setup and after a finished recovery.
    public var passwordHash: PasswordHash?
    /// Every blocked site, in the order added.
    public var blocked: [BlockedSite]
    /// The current unblock waiting period in seconds.
    public var delaySeconds: Int
    /// A shorter waiting period that has been requested but has not applied yet.
    public var pendingDelayChange: PendingDelayChange?
    /// A requested uninstall that has not taken effect yet.
    public var pendingUninstall: Countdown?
    /// A running forgotten-password reset.
    public var recovery: Countdown?
    /// Wrong passwords since the last correct one or the last lockout.
    public var failedAttempts: Int
    /// Time left before password checks are allowed again.
    public var lockout: Countdown?
    /// Set to true when an uninstall starts so the watchdog stops reloading the daemon.
    public var uninstalling: Bool

    /// Creates a state record from every field.
    public init(version: Int = PersistedState.currentVersion, passwordHash: PasswordHash? = nil, blocked: [BlockedSite] = [], delaySeconds: Int, pendingDelayChange: PendingDelayChange? = nil, pendingUninstall: Countdown? = nil, recovery: Countdown? = nil, failedAttempts: Int = 0, lockout: Countdown? = nil, uninstalling: Bool = false) {
        self.version = version
        self.passwordHash = passwordHash
        self.blocked = blocked
        self.delaySeconds = delaySeconds
        self.pendingDelayChange = pendingDelayChange
        self.pendingUninstall = pendingUninstall
        self.recovery = recovery
        self.failedAttempts = failedAttempts
        self.lockout = lockout
        self.uninstalling = uninstalling
    }

    /// The state of a brand-new install: no password, nothing blocked, nothing pending.
    public static func fresh(delaySeconds: Int = 1800) -> PersistedState {
        PersistedState(delaySeconds: delaySeconds)
    }

    /// True only when the state describes a real uninstall: the `uninstalling` flag is set, an uninstall countdown exists, and it has run out. The flag alone is not enough, because anyone who can edit the state file could set it to make the daemon uninstall itself without the password and the wait.
    public var hasFinishedUninstall: Bool {
        uninstalling && pendingUninstall?.isFinished == true
    }
}
