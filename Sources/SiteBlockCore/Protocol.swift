import Foundation

/// The shared JSON encoder and decoder used for the socket protocol and the state file.
public enum JSONCoding {
    /// Encodes with sorted keys and no pretty-printing, so every message is a single line of JSON.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Decodes with default settings.
    public static let decoder = JSONDecoder()
}

/// Every command a client can send to the daemon; the raw values are the names on the wire.
public enum Command: String, Codable, CaseIterable, Sendable {
    case status
    case setup
    case add
    case unblock
    case cancelUnblock
    case addPath
    case unblockPath
    case cancelUnblockPath
    case temporaryUnblock
    case temporaryUnblockPath
    case setDelay
    case cancelDelayChange
    case changePassword
    case uninstall
    case cancelUninstall
    case recoveryStart
    case recoveryCancel
}

/// The stable machine-readable reasons a command can fail; the raw values are the codes on the wire.
public enum ErrorCode: String, Codable, CaseIterable, Sendable {
    case badRequest
    case invalidDomain
    case notSetUp
    case alreadySetUp
    case wrongPassword
    case lockedOut
    case weakPassword
    case notBlocked
    case alreadyBlocked
    case nothingPending
    case invalidDelay
    case notRoot
    case notAllowed
    case tooManySites
    case invalidPath
    case invalidDuration
    case alreadyPending
    case `internal`
}

/// One request from a client: a command plus the arguments that command needs.
public struct Request: Codable, Equatable, Sendable {
    /// Which command to run.
    public var command: Command
    /// The site for add, unblock, cancelUnblock and temporaryUnblock. For addPath, unblockPath, cancelUnblockPath and temporaryUnblockPath it holds the whole rule text, for example youtube.com/shorts or a pasted link.
    public var domain: String?
    /// The current password, for commands that loosen anything.
    public var password: String?
    /// The new password, for changePassword.
    public var newPassword: String?
    /// The delay in seconds, for setDelay. For temporaryUnblock and temporaryUnblockPath it is how long the site stays open (the window).
    public var seconds: Int?
    /// How long to wait before the site opens, in seconds, for temporaryUnblock and temporaryUnblockPath. Left out, it means the current unblock delay.
    public var startSeconds: Int?

    /// Creates a request; arguments the command does not use stay nil.
    public init(command: Command, domain: String? = nil, password: String? = nil, newPassword: String? = nil, seconds: Int? = nil, startSeconds: Int? = nil) {
        self.command = command
        self.domain = domain
        self.password = password
        self.newPassword = newPassword
        self.seconds = seconds
        self.startSeconds = startSeconds
    }
}

/// A temporary unblock as shown to clients.
public struct TemporaryUnblockStatus: Codable, Equatable, Sendable {
    /// Seconds until the site opens, rounded up; nil once it is open.
    public let opensInSeconds: Int?
    /// While waiting, the full length of the window; while open, the seconds left in the window, rounded up.
    public let secondsRemaining: Int
    /// The length of the window the person chose, in seconds.
    public let windowSeconds: Int
    /// True while the site is open.
    public let isOpen: Bool

    /// Creates a temporary unblock status.
    public init(opensInSeconds: Int?, secondsRemaining: Int, windowSeconds: Int, isOpen: Bool) {
        self.opensInSeconds = opensInSeconds
        self.secondsRemaining = secondsRemaining
        self.windowSeconds = windowSeconds
        self.isOpen = isOpen
    }
}

/// One blocked site as shown to clients.
public struct BlockedSiteStatus: Codable, Equatable, Sendable {
    /// The base name, for example reddit.com.
    public let domain: String
    /// Every host name written to the hosts file for this site.
    public let hosts: [String]
    /// Seconds until the site unblocks, or nil when no unblock is pending.
    public let unblockSecondsRemaining: Int?
    /// The site's temporary unblock, or nil when it has none. A reply from an older daemon has no such key, and then this reads as nil.
    public let temporaryUnblock: TemporaryUnblockStatus?

    /// Creates a site status; the temporary unblock defaults to none, the value a reader gets when the key is missing.
    public init(domain: String, hosts: [String], unblockSecondsRemaining: Int?, temporaryUnblock: TemporaryUnblockStatus? = nil) {
        self.domain = domain
        self.hosts = hosts
        self.unblockSecondsRemaining = unblockSecondsRemaining
        self.temporaryUnblock = temporaryUnblock
    }
}

/// One path rule as shown to clients.
public struct BlockedPathStatus: Codable, Equatable, Sendable {
    /// The base name, for example youtube.com.
    public let domain: String
    /// The path prefix, for example /shorts.
    public let path: String
    /// The domain and path joined as people read them, for example youtube.com/shorts. Clients also send this text back to unblock or cancel the rule.
    public let rule: String
    /// Seconds until the rule is removed, or nil when no unblock is pending.
    public let unblockSecondsRemaining: Int?
    /// The rule's temporary unblock, or nil when it has none. A reply from an older daemon has no such key, and then this reads as nil.
    public let temporaryUnblock: TemporaryUnblockStatus?

    /// Creates a path rule status; the temporary unblock defaults to none, the value a reader gets when the key is missing.
    public init(domain: String, path: String, rule: String, unblockSecondsRemaining: Int?, temporaryUnblock: TemporaryUnblockStatus? = nil) {
        self.domain = domain
        self.path = path
        self.rule = rule
        self.unblockSecondsRemaining = unblockSecondsRemaining
        self.temporaryUnblock = temporaryUnblock
    }
}

/// A pending shorter delay as shown to clients.
public struct PendingDelayStatus: Codable, Equatable, Sendable {
    /// The shorter delay that will apply.
    public let newDelaySeconds: Int
    /// Seconds before it applies.
    public let secondsRemaining: Int

    /// Creates a pending delay status.
    public init(newDelaySeconds: Int, secondsRemaining: Int) {
        self.newDelaySeconds = newDelaySeconds
        self.secondsRemaining = secondsRemaining
    }
}

/// A picture of the whole daemon state, sent with every successful response so clients can redraw after any command.
public struct StatusSnapshot: Codable, Equatable, Sendable {
    /// The daemon's version string.
    public let version: String
    /// True once a password has been set.
    public let passwordSet: Bool
    /// Every blocked site.
    public let blocked: [BlockedSiteStatus]
    /// The current unblock delay in seconds.
    public let delaySeconds: Int
    /// A requested shorter delay that has not applied yet.
    public let pendingDelay: PendingDelayStatus?
    /// Seconds until a requested uninstall happens.
    public let uninstallSecondsRemaining: Int?
    /// Seconds until a running password recovery finishes.
    public let recoverySecondsRemaining: Int?
    /// Seconds until password checks are allowed again.
    public let lockoutSecondsRemaining: Int?
    /// True when the last enforcement pass found or left the hosts file in the right state.
    public let hostsFileHealthy: Bool
    /// Whether the adult content filter is on. A daemon that has the filter always sends true. A reply from an older daemon has no such key, and then this reads as false, so a newer client never mistakes "the daemon does not know about the filter" for "the filter is on".
    public let adultFilterEnabled: Bool?
    /// Every path rule. A daemon that has path rules always sends the list (empty when there are none). A reply from an older daemon has no such key, and then this reads as an empty list.
    public let blockedPaths: [BlockedPathStatus]?

    /// Creates a snapshot from every field. `adultFilterEnabled` defaults to false and `blockedPaths` to an empty list, the values a reader gets when the keys are missing.
    public init(version: String, passwordSet: Bool, blocked: [BlockedSiteStatus], delaySeconds: Int, pendingDelay: PendingDelayStatus?, uninstallSecondsRemaining: Int?, recoverySecondsRemaining: Int?, lockoutSecondsRemaining: Int?, hostsFileHealthy: Bool, adultFilterEnabled: Bool? = false, blockedPaths: [BlockedPathStatus]? = []) {
        self.version = version
        self.passwordSet = passwordSet
        self.blocked = blocked
        self.delaySeconds = delaySeconds
        self.pendingDelay = pendingDelay
        self.uninstallSecondsRemaining = uninstallSecondsRemaining
        self.recoverySecondsRemaining = recoverySecondsRemaining
        self.lockoutSecondsRemaining = lockoutSecondsRemaining
        self.hostsFileHealthy = hostsFileHealthy
        self.adultFilterEnabled = adultFilterEnabled
        self.blockedPaths = blockedPaths
    }

    /// The keys of the JSON snapshot; spelled out so `init(from:)` can be written by hand.
    private enum CodingKeys: String, CodingKey {
        case version, passwordSet, blocked, delaySeconds, pendingDelay, uninstallSecondsRemaining, recoverySecondsRemaining, lockoutSecondsRemaining, hostsFileHealthy, adultFilterEnabled, blockedPaths
    }

    /// Reads a snapshot from JSON. Every field an older daemon sent stays as it was; `adultFilterEnabled` and `blockedPaths` are newer, so a missing `adultFilterEnabled` reads as false and a missing `blockedPaths` reads as an empty list. That keeps an old daemon and a new client (or the reverse) working together.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(String.self, forKey: .version)
        self.passwordSet = try container.decode(Bool.self, forKey: .passwordSet)
        self.blocked = try container.decode([BlockedSiteStatus].self, forKey: .blocked)
        self.delaySeconds = try container.decode(Int.self, forKey: .delaySeconds)
        self.pendingDelay = try container.decodeIfPresent(PendingDelayStatus.self, forKey: .pendingDelay)
        self.uninstallSecondsRemaining = try container.decodeIfPresent(Int.self, forKey: .uninstallSecondsRemaining)
        self.recoverySecondsRemaining = try container.decodeIfPresent(Int.self, forKey: .recoverySecondsRemaining)
        self.lockoutSecondsRemaining = try container.decodeIfPresent(Int.self, forKey: .lockoutSecondsRemaining)
        self.hostsFileHealthy = try container.decode(Bool.self, forKey: .hostsFileHealthy)
        self.adultFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .adultFilterEnabled) ?? false
        self.blockedPaths = try container.decodeIfPresent([BlockedPathStatus].self, forKey: .blockedPaths) ?? []
    }
}

/// The daemon's reply to one request.
public struct Response: Codable, Equatable, Sendable {
    /// True when the command succeeded.
    public let ok: Bool
    /// A sentence a person can read; present when ok is false.
    public let error: String?
    /// A stable machine-readable code; present when ok is false.
    public let errorCode: ErrorCode?
    /// Present on every successful response.
    public let status: StatusSnapshot?
    /// A short confirmation sentence for a successful command.
    public let message: String?

    /// Creates a response from every field.
    public init(ok: Bool, error: String? = nil, errorCode: ErrorCode? = nil, status: StatusSnapshot? = nil, message: String? = nil) {
        self.ok = ok
        self.error = error
        self.errorCode = errorCode
        self.status = status
        self.message = message
    }

    /// Builds a successful response carrying the current status and an optional confirmation sentence.
    public static func success(status: StatusSnapshot, message: String? = nil) -> Response {
        Response(ok: true, status: status, message: message)
    }

    /// Builds a failed response with a stable code and a readable sentence.
    public static func failure(_ code: ErrorCode, _ message: String) -> Response {
        Response(ok: false, error: message, errorCode: code)
    }
}
