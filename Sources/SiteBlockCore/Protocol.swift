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
    case `internal`
}

/// One request from a client: a command plus the arguments that command needs.
public struct Request: Codable, Equatable, Sendable {
    /// Which command to run.
    public var command: Command
    /// The site, for add, unblock and cancelUnblock.
    public var domain: String?
    /// The current password, for commands that loosen anything.
    public var password: String?
    /// The new password, for changePassword.
    public var newPassword: String?
    /// The delay in seconds, for setDelay.
    public var seconds: Int?

    /// Creates a request; arguments the command does not use stay nil.
    public init(command: Command, domain: String? = nil, password: String? = nil, newPassword: String? = nil, seconds: Int? = nil) {
        self.command = command
        self.domain = domain
        self.password = password
        self.newPassword = newPassword
        self.seconds = seconds
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

    /// Creates a site status.
    public init(domain: String, hosts: [String], unblockSecondsRemaining: Int?) {
        self.domain = domain
        self.hosts = hosts
        self.unblockSecondsRemaining = unblockSecondsRemaining
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

    /// Creates a snapshot from every field.
    public init(version: String, passwordSet: Bool, blocked: [BlockedSiteStatus], delaySeconds: Int, pendingDelay: PendingDelayStatus?, uninstallSecondsRemaining: Int?, recoverySecondsRemaining: Int?, lockoutSecondsRemaining: Int?, hostsFileHealthy: Bool) {
        self.version = version
        self.passwordSet = passwordSet
        self.blocked = blocked
        self.delaySeconds = delaySeconds
        self.pendingDelay = pendingDelay
        self.uninstallSecondsRemaining = uninstallSecondsRemaining
        self.recoverySecondsRemaining = recoverySecondsRemaining
        self.lockoutSecondsRemaining = lockoutSecondsRemaining
        self.hostsFileHealthy = hostsFileHealthy
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
