import Foundation

/// The first two parts of the version people see. To start a new series (for example 1.3), change this and `siteBlockSeriesFirstBuild` together.
public let siteBlockSeries = "1.3"
/// The build number of the first build in the current series, which is released as <series>.0.
public let siteBlockSeriesFirstBuild = 95
/// The release number. To publish a Mac release, raise it by one and push to master: GitHub's package workflow publishes a build only when this number is
/// higher than the published one, so a push that leaves it alone is built and tested but not released. Installed copies take an update only when its number is
/// higher than their own, so this number never goes down.
public let siteBlockBuildNumber = 94
/// The version number people see: the series followed by how far the build number is past the series' first build, so the series starts at 1.2.0 and counts
/// 1.2.1, 1.2.2 and so on, one per release, and starts again at .0 when the series changes. Updates are ordered by the build number, never by this text, so starting
/// again at .0 never hides an update.
public let siteBlockMarketingVersion = "\(siteBlockSeries).\(max(0, siteBlockBuildNumber - siteBlockSeriesFirstBuild))"
/// The version shown in the app, the CLI and the daemon's status reply, for example "1.2.0". The build number is shown only by `siteblockd --version`, which the build scripts read.
public let siteBlockVersion = siteBlockMarketingVersion
/// The technical build id written to version.json's `version` field: 1.0 followed by the build number. Copies of SiteBlock older than 1.2.0 accept an update only when that field reads exactly so, so it keeps this form and the version people see goes in `displayVersion`.
public let siteBlockBuildID = "1.0.\(siteBlockBuildNumber)"

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

/// An unblock for a limited time that the person asked for on a site or path rule. The site stays blocked while `startsIn` runs down, stays open for exactly `window`, and is then blocked again on its own; the site or rule itself never leaves the block list.
public struct TemporaryUnblock: Codable, Equatable, Sendable {
    /// Time left before the site opens. It starts at the start wait the person chose.
    public var startsIn: Countdown
    /// How long the site stays open. It starts counting down only after `startsIn` has reached 0.
    public var window: Countdown

    /// Creates a temporary unblock from its two countdowns.
    public init(startsIn: Countdown, window: Countdown) {
        self.startsIn = startsIn
        self.window = window
    }

    /// True while the site is open: the start wait is over and the window still has time left.
    public var isOpen: Bool { startsIn.remainingSeconds <= 0 && window.remainingSeconds > 0 }

    /// True once both the start wait and the window have run out, which means the site is blocked again and this record can be removed.
    public var isFinished: Bool { startsIn.remainingSeconds <= 0 && window.remainingSeconds <= 0 }

    /// The length of the window the person chose, in whole seconds. It does not change as time passes.
    public var windowSeconds: Int {
        guard window.totalSeconds.isFinite, window.totalSeconds > 0 else { return 0 }
        // The upper bound keeps the Int conversion safe for absurd stored values.
        return Int(min(window.totalSeconds, 1e12).rounded(.up))
    }

    /// Subtracts real elapsed time. The start wait uses it first; whatever the start wait did not need (because it reached 0 during this step) comes off the window, and once the start wait is over all of it comes off the window. Neither countdown goes below 0. Negative or non-finite input changes nothing.
    public mutating func advance(by elapsed: Double) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        // How much of this step the start wait can still take; a stored negative or odd value counts as nothing left.
        let usedByStart = min(elapsed, max(0, startsIn.remainingSeconds))
        startsIn.advance(by: elapsed)
        window.advance(by: elapsed - usedByStart)
    }
}

/// One blocked site: the name the user asked for, every host name written to the hosts file for it, and an optional unblock that is waiting out its delay or a temporary unblock the person scheduled. The two never exist on the same site at once.
public struct BlockedSite: Codable, Equatable, Sendable {
    /// The normalized base name, for example reddit.com.
    public var domain: String
    /// The full expanded host list, sorted and without duplicates.
    public var hosts: [String]
    /// Set when an unblock was approved; when it reaches zero the site is removed.
    public var pendingUnblock: Countdown?
    /// Set when a temporary unblock was approved; the site opens after its start wait and is blocked again when its window ends. A state file written before temporary unblocks existed has no such key, and a missing key reads as nil, so such a file still loads.
    public var temporaryUnblock: TemporaryUnblock?

    /// Creates a blocked site record.
    public init(domain: String, hosts: [String], pendingUnblock: Countdown? = nil, temporaryUnblock: TemporaryUnblock? = nil) {
        self.domain = domain
        self.hosts = hosts
        self.pendingUnblock = pendingUnblock
        self.temporaryUnblock = temporaryUnblock
    }

    /// True while a temporary unblock has this site open, which means its hosts are left out of the hosts file and the browsers' lists.
    public var isTemporarilyOpen: Bool { temporaryUnblock?.isOpen == true }

    /// The names of the stored fields.
    private enum CodingKeys: String, CodingKey { case domain, hosts, pendingUnblock, temporaryUnblock }

    /// Reads a saved site. A temporary unblock that is present but cannot be read (for example a hand-edited record missing its window) is dropped instead of failing the whole file: a state file that fails to load is set aside, which could take the whole block list with it, while dropping the record only means the site stays blocked.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(String.self, forKey: .domain)
        hosts = try container.decode([String].self, forKey: .hosts)
        pendingUnblock = try container.decodeIfPresent(Countdown.self, forKey: .pendingUnblock)
        temporaryUnblock = try? container.decodeIfPresent(TemporaryUnblock.self, forKey: .temporaryUnblock)
    }
}

/// One path rule: the start of a path on a site that stays blocked while the rest of the site stays open, for example `/shorts` on youtube.com. Only the browsers' own block lists can enforce it; the hosts file can only block whole names.
public struct BlockedPath: Codable, Equatable, Sendable {
    /// The normalized base domain, for example youtube.com.
    public var domain: String
    /// The path prefix, starting with "/", for example /shorts. Its case is kept, because paths are case-sensitive.
    public var path: String
    /// Set when an unblock was approved; when it reaches zero the rule is removed.
    public var pendingUnblock: Countdown?
    /// Set when a temporary unblock was approved; the rule stops blocking after its start wait and blocks again when its window ends. A missing key reads as nil, as for a site.
    public var temporaryUnblock: TemporaryUnblock?

    /// Creates a path rule record.
    public init(domain: String, path: String, pendingUnblock: Countdown? = nil, temporaryUnblock: TemporaryUnblock? = nil) {
        self.domain = domain
        self.path = path
        self.pendingUnblock = pendingUnblock
        self.temporaryUnblock = temporaryUnblock
    }

    /// True while a temporary unblock has this rule open, which means the browsers' lists leave it out.
    public var isTemporarilyOpen: Bool { temporaryUnblock?.isOpen == true }

    /// The names of the stored fields.
    private enum CodingKeys: String, CodingKey { case domain, path, pendingUnblock, temporaryUnblock }

    /// Reads a saved path rule. As for a site, a temporary unblock that is present but cannot be read is dropped, so the rule stays blocked and the rest of the file still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(String.self, forKey: .domain)
        path = try container.decode(String.self, forKey: .path)
        pendingUnblock = try container.decodeIfPresent(Countdown.self, forKey: .pendingUnblock)
        temporaryUnblock = try? container.decodeIfPresent(TemporaryUnblock.self, forKey: .temporaryUnblock)
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
    /// For each network service (keyed by its SystemConfiguration service ID), the DNS servers it had before SiteBlock replaced them with the family servers; an empty list means the service had none set by hand. Written the first time a service is overridden and used only by the uninstaller to put the originals back. Nil until the first override, and nil in any state file written before the adult content filter existed.
    public var savedDNS: [String: [String]]?
    /// Every path rule, in the order added. Nil until the first rule is added, and nil in any state file written before path rules existed.
    public var blockedPaths: [BlockedPath]?

    /// Creates a state record from every field.
    public init(version: Int = PersistedState.currentVersion, passwordHash: PasswordHash? = nil, blocked: [BlockedSite] = [], delaySeconds: Int, pendingDelayChange: PendingDelayChange? = nil, pendingUninstall: Countdown? = nil, recovery: Countdown? = nil, failedAttempts: Int = 0, lockout: Countdown? = nil, uninstalling: Bool = false, savedDNS: [String: [String]]? = nil, blockedPaths: [BlockedPath]? = nil) {
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
        self.savedDNS = savedDNS
        self.blockedPaths = blockedPaths
    }

    /// The keys of the stored JSON; spelled out so `init(from:)` can be written by hand.
    private enum CodingKeys: String, CodingKey {
        case version, passwordHash, blocked, delaySeconds, pendingDelayChange, pendingUninstall, recovery, failedAttempts, lockout, uninstalling, savedDNS, blockedPaths
    }

    /// Reads a state from JSON. The fields that existed in the first release stay required, so a file missing one (such as `{}`) is still rejected as damaged. `savedDNS` and `blockedPaths` were added later, so a file written before they existed must still load with its sites intact, and a missing key becomes nil. Without that, an old file would count as corrupt, be set aside, and the daemon would start with an empty block list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.passwordHash = try container.decodeIfPresent(PasswordHash.self, forKey: .passwordHash)
        self.blocked = try container.decode([BlockedSite].self, forKey: .blocked)
        self.delaySeconds = try container.decode(Int.self, forKey: .delaySeconds)
        self.pendingDelayChange = try container.decodeIfPresent(PendingDelayChange.self, forKey: .pendingDelayChange)
        self.pendingUninstall = try container.decodeIfPresent(Countdown.self, forKey: .pendingUninstall)
        self.recovery = try container.decodeIfPresent(Countdown.self, forKey: .recovery)
        self.failedAttempts = try container.decode(Int.self, forKey: .failedAttempts)
        self.lockout = try container.decodeIfPresent(Countdown.self, forKey: .lockout)
        self.uninstalling = try container.decode(Bool.self, forKey: .uninstalling)
        self.savedDNS = try container.decodeIfPresent([String: [String]].self, forKey: .savedDNS)
        self.blockedPaths = try container.decodeIfPresent([BlockedPath].self, forKey: .blockedPaths)
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
