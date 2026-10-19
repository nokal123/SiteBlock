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
    /// The most sites and path rules that can be blocked at once, counted together. Adding a new site or rule beyond this fails with tooManySites.
    public var maxSites: Int
    /// The shortest an uninstall ever waits. The real wait is this or the unblock delay, whichever is longer, so uninstalling is never a faster way to unblock everything than unblocking.
    public var minUninstallSeconds: Int
    /// The shortest time a temporary unblock may stay open.
    public var minTemporarySeconds: Int
    /// The longest time a temporary unblock may stay open.
    public var maxTemporarySeconds: Int
    /// The longest wait before a temporary unblock opens.
    public var maxTemporaryStartSeconds: Int

    /// Creates a policy from every value. `maxSites`, `minUninstallSeconds` and the three temporary unblock limits default to the production values (500 sites and path rules together, 48 hours, 5 minutes to 4 hours open, up to 7 days before it opens), so callers that predate them keep compiling.
    public init(defaultDelaySeconds: Int, minDelaySeconds: Int, maxDelaySeconds: Int, recoverySeconds: Int, lockoutSeconds: Int, maxFailedAttempts: Int, pbkdf2Iterations: Int, maxSites: Int = 500, minUninstallSeconds: Int = 172_800, minTemporarySeconds: Int = 300, maxTemporarySeconds: Int = 14_400, maxTemporaryStartSeconds: Int = 604_800) {
        self.defaultDelaySeconds = defaultDelaySeconds
        self.minDelaySeconds = minDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.recoverySeconds = recoverySeconds
        self.lockoutSeconds = lockoutSeconds
        self.maxFailedAttempts = maxFailedAttempts
        self.pbkdf2Iterations = pbkdf2Iterations
        self.maxSites = maxSites
        self.minUninstallSeconds = minUninstallSeconds
        self.minTemporarySeconds = minTemporarySeconds
        self.maxTemporarySeconds = maxTemporarySeconds
        self.maxTemporaryStartSeconds = maxTemporaryStartSeconds
    }

    /// The values the installed service always uses: 30 minute delay, 60 second to 7 day range, 48 hour recovery, 15 minute lockout after 5 wrong passwords, at most 500 blocked sites and path rules together, an uninstall wait of at least 48 hours, and a temporary unblock that stays open 5 minutes to 4 hours and opens within 7 days.
    public static let production = Policy(defaultDelaySeconds: 1800, minDelaySeconds: 60, maxDelaySeconds: 604_800, recoverySeconds: 172_800, lockoutSeconds: 900, maxFailedAttempts: 5, pbkdf2Iterations: 210_000, maxSites: 500, minUninstallSeconds: 172_800, minTemporarySeconds: 300, maxTemporarySeconds: 14_400, maxTemporaryStartSeconds: 604_800)

    /// Short waits and a low site cap (20) for sandbox runs and tests only, so tests can reach the cap quickly. A temporary unblock may stay open for as little as 1 second, so a test can open and close a window in seconds; its other limits are the production ones.
    public static let fastForTests = Policy(defaultDelaySeconds: 2, minDelaySeconds: 1, maxDelaySeconds: 604_800, recoverySeconds: 3, lockoutSeconds: 2, maxFailedAttempts: 5, pbkdf2Iterations: 1000, maxSites: 20, minUninstallSeconds: 2, minTemporarySeconds: 1, maxTemporarySeconds: 14_400, maxTemporaryStartSeconds: 604_800)
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
    /// Called with one plain sentence whenever a temporary unblock is approved, opens, ends on its own, or is cancelled or ended early. The daemon writes each sentence to its log. The sentences never name the site or rule, because the log file stays on disk and would become a dated list of which sites were opened.
    public var onTemporaryUnblockEvent: ((String) -> Void)?
    /// Returns the user ID of the person logged in at the screen, or nil when it is not known. The daemon sets it in production to read the owner of /dev/console. While it returns nil (the default, used by sandbox runs and tests), any caller may run setup. When it returns an ID, only root or that user may.
    public var consoleUID: () -> uid_t? = { nil }
    // The result of the last hosts file enforcement pass, reported in every status. It starts true because the runtime enforces once at startup and then sets it.
    private var lastHostsHealthy = true

    /// Creates an engine around loaded (or fresh) state and a policy.
    public init(state: PersistedState, policy: Policy) {
        self.state = state
        self.policy = policy
    }

    /// The sites that are blocked right now: every site except the ones a temporary unblock has open. Sites with a pending unblock are included, because they stay blocked until the countdown ends, and so are sites whose temporary unblock is still waiting to open.
    private var enforcedSites: [BlockedSite] { state.blocked.filter { !$0.isTemporarilyOpen } }

    /// Every host of every blocked site, sorted, without duplicates. Sites with a pending unblock are included, because they stay blocked until the countdown ends. A site whose temporary unblock is open is left out, but a host that another site (one that is not open) also needs stays in the list.
    public var blockedHosts: [String] {
        Array(Set(enforcedSites.flatMap { $0.hosts })).sorted()
    }

    /// The host names iCloud Private Relay needs. Apple documents blocking these as the way a network turns Private Relay off, and Private Relay would otherwise send Safari's lookups to Apple's servers past the hosts file.
    public static let privateRelayHosts = ["mask-h2.icloud.com", "mask.icloud.com"]

    /// True while the adult content filter is in force, which is always, except once an uninstall has begun (the uninstaller then takes the filter's settings away). There is no command, password or wait that turns it off.
    public var adultFilterActive: Bool { !state.uninstalling }

    /// The host names browsers use for their own DNS-over-HTTPS by default (Firefox's Cloudflare, NextDNS and CIRA servers, and Comcast's). A browser that looks names up this way skips both the hosts file and the family DNS servers, so the hosts file always blocks these names and the browser falls back to the Mac's own lookups.
    public static let dohBypassHosts = ["doh.xfinity.com", "firefox.dns.nextdns.io", "mozilla.cloudflare-dns.com", "private.canadianshield.cira.ca"]

    /// Everything the hosts file must block: every blocked site's hosts, plus the Private Relay names and the DNS-over-HTTPS names whenever the adult content filter is active. The filter sets the Mac's DNS servers to the family servers, and Private Relay or a browser's own DNS-over-HTTPS would send lookups elsewhere, so those names stay blocked even with no site on the list. Path rules never add hosts, because the hosts file can only block whole names.
    public var hostsToWrite: [String] {
        let hosts = adultFilterActive ? blockedHosts + Engine.privateRelayHosts + Engine.dohBypassHosts : blockedHosts
        return Array(Set(hosts)).sorted()
    }

    /// The path rules, or an empty list when there are none.
    private var pathRules: [BlockedPath] { state.blockedPaths ?? [] }

    /// What the browsers' block lists must hold, with whole-site and path entries kept apart (so the enforcer can cut a too-long list with the whole-site entries kept first). The whole-site part is the shortest list that covers every host of every blocked site; a path rule is left out when a whole-site block already covers its domain, because the whole site is blocked anyway. Sites and rules with a pending unblock are included, because they stay blocked until the countdown ends. A site or rule whose temporary unblock is open is left out. A path rule whose whole site is open is kept, because the whole-site entry is gone and the rule is what still blocks that part.
    public var browserBlockLists: BrowserBlockLists {
        let sites = ChromePolicy.urlBlocklist(for: enforcedSites)
        // The covering check runs against the sites that are still blocked, so a rule is dropped as redundant only when a site that is not open covers it.
        let rules = pathRules.filter { !$0.isTemporarilyOpen && !ChromePolicy.covers(sites, host: $0.domain) }
        return BrowserBlockLists(
            chromeSites: sites,
            chromePaths: Array(Set(rules.map { PathRuleParser.chromeEntry(domain: $0.domain, path: $0.path) })).sorted(),
            firefoxSites: sites.map { "*://*.\($0)/*" },
            firefoxPaths: Array(Set(rules.map { PathRuleParser.firefoxPattern(domain: $0.domain, path: $0.path) })).sorted()
        )
    }

    /// Both browsers' block lists as plain sorted lists: `chrome` for Chrome, Edge and Brave, and `firefox` for Firefox.
    public var browserBlockEntries: (chrome: [String], firefox: [String]) {
        let lists = browserBlockLists
        return (lists.chrome, lists.firefox)
    }

    /// Records the original DNS servers the DNS enforcer found (keyed by network service ID), or clears the record with nil or an empty dictionary. The enforcer calls this before it overrides a service, so the originals are known to the engine (and saved with the state) before they are lost.
    public func setSavedDNS(_ saved: [String: [String]]?) {
        state.savedDNS = (saved?.isEmpty ?? true) ? nil : saved
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
            blocked: state.blocked.map { BlockedSiteStatus(domain: $0.domain, hosts: $0.hosts, unblockSecondsRemaining: $0.pendingUnblock?.displaySeconds, temporaryUnblock: $0.temporaryUnblock.map(temporaryStatus)) },
            delaySeconds: state.delaySeconds,
            pendingDelay: state.pendingDelayChange.map { PendingDelayStatus(newDelaySeconds: $0.newDelaySeconds, secondsRemaining: $0.countdown.displaySeconds) },
            uninstallSecondsRemaining: state.pendingUninstall?.displaySeconds,
            recoverySecondsRemaining: state.recovery?.displaySeconds,
            lockoutSecondsRemaining: state.lockout?.displaySeconds,
            hostsFileHealthy: hostsFileHealthy,
            // The filter cannot be switched off, so a daemon that has it always says so. (A daemon from before the filter existed sends no such key, which clients read as false.)
            adultFilterEnabled: true,
            blockedPaths: pathRules.map { BlockedPathStatus(domain: $0.domain, path: $0.path, rule: PathRuleParser.display(domain: $0.domain, path: $0.path), unblockSecondsRemaining: $0.pendingUnblock?.displaySeconds, temporaryUnblock: $0.temporaryUnblock.map(temporaryStatus)) }
        )
    }

    /// Describes a temporary unblock for clients. While it waits, `opensInSeconds` counts down and `secondsRemaining` is the whole window; once it is open, `opensInSeconds` is nil and `secondsRemaining` counts down the window. Both are rounded up, so a running countdown never shows 0. The window has not started counting while the site waits, so its remaining time is the whole window in both states.
    private func temporaryStatus(_ unblock: TemporaryUnblock) -> TemporaryUnblockStatus {
        TemporaryUnblockStatus(opensInSeconds: unblock.startsIn.isFinished ? nil : unblock.startsIn.displaySeconds, secondsRemaining: unblock.window.displaySeconds, windowSeconds: unblock.windowSeconds, isOpen: unblock.isOpen)
    }

    // MARK: - Commands

    /// Runs one command and always returns a response; it never throws. Every successful response carries the current status.
    public func handle(_ request: Request, peerUID: uid_t) -> Response {
        do {
            switch request.command {
            case .status: return success(nil)
            case .setup: return try setup(request, peerUID: peerUID)
            case .add: return try add(request)
            case .unblock: return try unblock(request)
            case .cancelUnblock: return try cancelUnblock(request)
            case .addPath: return try addPath(request)
            case .unblockPath: return try unblockPath(request)
            case .cancelUnblockPath: return try cancelUnblockPath(request)
            case .temporaryUnblock: return try scheduleTemporaryUnblock(request, forRule: false)
            case .temporaryUnblockPath: return try scheduleTemporaryUnblock(request, forRule: true)
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

    /// Sets the first password; fails when the caller is not allowed to, when one already exists, or when the new one is too weak.
    private func setup(_ request: Request, peerUID: uid_t) throws -> Response {
        // Who may set the password is checked first, before the arguments and before "already set up", so another account on the Mac learns nothing and cannot claim the password before the owner does (or right after a recovery clears it).
        if let console = consoleUID(), peerUID != 0, peerUID != console {
            throw reject(.notAllowed, "Only the administrator or the person logged in at this Mac's screen can set the SiteBlock password.")
        }
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

    /// Blocks a site at once. If the site is already blocked with an unblock pending, or with a temporary unblock (waiting or open), it cancels that unblock instead.
    private func add(_ request: Request) throws -> Response {
        let raw = try require(request.domain, "domain")
        let domain = try normalized(raw)
        if let index = state.blocked.firstIndex(where: { $0.domain == domain }) {
            // Re-adding a site that is waiting to unblock, or that has a temporary unblock, is a way to say "keep it blocked". Neither needs a password, because it only makes things stricter.
            let target = Target(isRule: false, index: index, name: domain)
            if pendingUnblock(of: target) != nil {
                clearPendingUnblock(of: target)
                return success("Unblock cancelled; \(domain) stays blocked.")
            }
            if let message = cancelTemporaryUnblock(of: target) { return success(message) }
            throw reject(.alreadyBlocked, "\(domain) is already blocked.")
        }
        // Every block must be undoable later, so blocking needs a password to exist. The check comes after the existing-site case so cancelling a pending unblock never needs one.
        guard state.passwordHash != nil else { throw reject(.notSetUp, "Set a password before blocking sites, so every block can be undone later.") }
        // The cap applies only to a new site (re-adding one that is waiting to unblock returned above). Without it, any account on the Mac could add thousands of sites with no password, and the owner would then need one password check and one wait per site to clear them.
        try requireRoomForOneMore()
        state.blocked.append(BlockedSite(domain: domain, hosts: DomainExpander.expand(domain)))
        return success("\(domain) is now blocked.")
    }

    /// Rejects with tooManySites when sites and path rules together have already reached the cap. A path rule counts like a site, because each one costs the owner a password check and a wait to clear.
    private func requireRoomForOneMore() throws {
        guard state.blocked.count + pathRules.count < policy.maxSites else { throw reject(.tooManySites, "SiteBlock can block at most \(policy.maxSites) sites and parts of sites together. Unblock one before adding another.") }
    }

    /// Starts the unblock countdown for a site after the password check. A second request keeps the running countdown rather than restarting it.
    private func unblock(_ request: Request) throws -> Response {
        let raw = try require(request.domain, "domain")
        let password = try require(request.password, "password")
        let domain = try normalized(raw)
        guard let index = state.blocked.firstIndex(where: { $0.domain == domain }) else { throw reject(.notBlocked, "\(domain) is not blocked.") }
        // A permanent unblock cannot start while a temporary one exists. This check comes before the password check, so a request that is refused anyway never costs a password attempt.
        if state.blocked[index].temporaryUnblock != nil { throw reject(.alreadyPending, "\(domain) has a temporary unblock. Keep it blocked first if you want to unblock it for good.") }
        if let denied = checkPassword(password) { return denied }
        if let existing = state.blocked[index].pendingUnblock {
            return success("\(domain) is already waiting to unblock, in \(Formatting.duration(existing.displaySeconds)). You can cancel any time before then.")
        }
        state.blocked[index].pendingUnblock = Countdown(seconds: Double(state.delaySeconds))
        return success("\(domain) will unblock in \(Formatting.duration(state.delaySeconds)). You can cancel any time before then.")
    }

    /// Stops a pending unblock, or ends a temporary unblock (waiting or open); needs no password because it makes the Mac stricter.
    private func cancelUnblock(_ request: Request) throws -> Response {
        let raw = try require(request.domain, "domain")
        let domain = try normalized(raw)
        guard let index = state.blocked.firstIndex(where: { $0.domain == domain }) else { throw reject(.notBlocked, "\(domain) is not blocked.") }
        return try cancelAnyUnblock(of: Target(isRule: false, index: index, name: domain))
    }

    /// The shared body of cancelUnblock and cancelUnblockPath. A pending unblock is cleared first, as it always was. Otherwise a temporary unblock is ended, and when there is neither the request fails with nothingPending.
    private func cancelAnyUnblock(of target: Target) throws -> Response {
        if pendingUnblock(of: target) != nil {
            clearPendingUnblock(of: target)
            return success("Unblock cancelled; \(target.name) stays blocked.")
        }
        if let message = cancelTemporaryUnblock(of: target) { return success(message) }
        throw reject(.nothingPending, "\(target.name) has no unblock waiting.")
    }

    /// Reads rule text such as `youtube.com/shorts` or a pasted link into a domain and a path. A problem with the site name rejects with invalidDomain; a problem with the path, or no path at all, rejects with invalidPath. Both carry the parser's own sentence.
    private func parsedRule(_ raw: String) throws -> (domain: String, path: String) {
        do {
            return try PathRuleParser.parse(raw)
        } catch let error as PathRuleError {
            throw reject(.invalidPath, error.localizedDescription)
        } catch {
            throw reject(.invalidDomain, error.localizedDescription)
        }
    }

    /// The position of the path rule with this domain and path, or nil when there is none.
    private func pathRuleIndex(_ rule: (domain: String, path: String)) -> Int? {
        pathRules.firstIndex { $0.domain == rule.domain && $0.path == rule.path }
    }

    /// Blocks part of a site at once. Fails with alreadyBlocked when the whole site is already blocked (the rule would add nothing) or the same rule exists; re-adding a rule that is waiting to unblock cancels the unblock instead, like `add`.
    private func addPath(_ request: Request) throws -> Response {
        let raw = try require(request.domain, "domain")
        let rule = try parsedRule(raw)
        let text = PathRuleParser.display(domain: rule.domain, path: rule.path)
        if state.blocked.contains(where: { $0.domain == rule.domain }) { throw reject(.alreadyBlocked, "\(rule.domain) is already fully blocked.") }
        if let index = pathRuleIndex(rule) {
            // Like `add`: re-adding a rule that is waiting to unblock, or that has a temporary unblock, keeps it blocked, with no password.
            let target = Target(isRule: true, index: index, name: text)
            if pendingUnblock(of: target) != nil {
                clearPendingUnblock(of: target)
                return success("Unblock cancelled; \(text) stays blocked.")
            }
            if let message = cancelTemporaryUnblock(of: target) { return success(message) }
            throw reject(.alreadyBlocked, "\(text) is already blocked.")
        }
        // The same two checks as `add`: every block must be undoable later, and the cap counts sites and rules together.
        guard state.passwordHash != nil else { throw reject(.notSetUp, "Set a password before blocking sites, so every block can be undone later.") }
        try requireRoomForOneMore()
        state.blockedPaths = pathRules + [BlockedPath(domain: rule.domain, path: rule.path)]
        return success("\(text) is now blocked.")
    }

    /// Starts the unblock countdown for a path rule after the password check, with the same rules as `unblock`: a second request keeps the running countdown.
    private func unblockPath(_ request: Request) throws -> Response {
        let raw = try require(request.domain, "domain")
        let password = try require(request.password, "password")
        let rule = try parsedRule(raw)
        let text = PathRuleParser.display(domain: rule.domain, path: rule.path)
        guard let index = pathRuleIndex(rule) else { throw reject(.notBlocked, "\(text) is not blocked.") }
        // Same as `unblock`: a temporary unblock must be cancelled first, and this is checked before the password.
        if state.blockedPaths?[index].temporaryUnblock != nil { throw reject(.alreadyPending, "\(text) has a temporary unblock. Keep it blocked first if you want to unblock it for good.") }
        if let denied = checkPassword(password) { return denied }
        if let existing = state.blockedPaths?[index].pendingUnblock {
            return success("\(text) is already waiting to unblock, in \(Formatting.duration(existing.displaySeconds)). You can cancel any time before then.")
        }
        // The countdown is built before the rule is touched: writing through `state.blockedPaths?` while reading `state.delaySeconds` in the same statement is an overlapping access to `state`, which Swift stops with a crash.
        let countdown = Countdown(seconds: Double(state.delaySeconds))
        state.blockedPaths?[index].pendingUnblock = countdown
        return success("\(text) will unblock in \(Formatting.duration(state.delaySeconds)). You can cancel any time before then.")
    }

    /// Stops a pending path-rule unblock, or ends a temporary unblock of the rule (waiting or open); needs no password because it makes the Mac stricter.
    private func cancelUnblockPath(_ request: Request) throws -> Response {
        let raw = try require(request.domain, "domain")
        let rule = try parsedRule(raw)
        let text = PathRuleParser.display(domain: rule.domain, path: rule.path)
        guard let index = pathRuleIndex(rule) else { throw reject(.notBlocked, "\(text) is not blocked.") }
        return try cancelAnyUnblock(of: Target(isRule: true, index: index, name: text))
    }

    // MARK: - Temporary unblocks

    /// A blocked site or path rule found by name: which list it sits in, its position there, and the text people read for it (the domain, or a rule such as youtube.com/shorts). The temporary unblock commands and the cancel commands work on both kinds through this.
    private struct Target {
        /// True for a path rule, false for a whole site.
        let isRule: Bool
        /// The position in `state.blocked` (a site) or `state.blockedPaths` (a rule).
        let index: Int
        /// The domain, or the rule text.
        let name: String
    }

    /// The unblock countdown the target is waiting on, or nil when it has none.
    private func pendingUnblock(of target: Target) -> Countdown? {
        target.isRule ? pathRules[target.index].pendingUnblock : state.blocked[target.index].pendingUnblock
    }

    /// Removes the target's pending unblock countdown, so the site or rule stays blocked.
    private func clearPendingUnblock(of target: Target) {
        if target.isRule {
            state.blockedPaths?[target.index].pendingUnblock = nil
        } else {
            state.blocked[target.index].pendingUnblock = nil
        }
    }

    /// The target's temporary unblock, or nil when it has none.
    private func temporaryUnblock(of target: Target) -> TemporaryUnblock? {
        target.isRule ? pathRules[target.index].temporaryUnblock : state.blocked[target.index].temporaryUnblock
    }

    /// Stores (or, with nil, removes) the target's temporary unblock. The value is passed in whole, so no part of `state` is read while it is being written.
    private func setTemporaryUnblock(_ unblock: TemporaryUnblock?, of target: Target) {
        if target.isRule {
            state.blockedPaths?[target.index].temporaryUnblock = unblock
        } else {
            state.blocked[target.index].temporaryUnblock = unblock
        }
    }

    /// Ends the target's temporary unblock, if it has one, and returns the sentence to tell the client: one for an unblock that was still waiting (the site never opened) and one for an unblock that was open (the site is blocked again now). Returns nil when the target has no temporary unblock. Both cases are sent to `onTemporaryUnblockEvent`.
    private func cancelTemporaryUnblock(of target: Target) -> String? {
        guard let unblock = temporaryUnblock(of: target) else { return nil }
        setTemporaryUnblock(nil, of: target)
        if unblock.isOpen {
            onTemporaryUnblockEvent?("temporary unblock ended early")
            return "\(target.name) is blocked again."
        }
        onTemporaryUnblockEvent?("temporary unblock cancelled")
        return "The temporary unblock is cancelled; \(target.name) stays blocked."
    }

    /// Schedules a temporary unblock of a site (or of a path rule when `forRule` is true). The checks run in a fixed order, and the password is checked last, so a malformed or refused request never costs a password attempt: missing arguments, the site or rule text, whether it is blocked, whether it already has an unblock, the window length, the start wait, and then the password.
    private func scheduleTemporaryUnblock(_ request: Request, forRule: Bool) throws -> Response {
        // 1. Every required argument must be present. Only `startSeconds` may be left out.
        let raw = try require(request.domain, "domain")
        let password = try require(request.password, "password")
        let windowSeconds = try require(request.seconds, "seconds")
        // 2 and 3. The site name or rule text must be valid, and the site or rule must be on the block list.
        let target = try forRule ? ruleTarget(raw) : siteTarget(raw)
        // 4. A site or rule can have only one unblock of either kind at a time.
        if pendingUnblock(of: target) != nil { throw reject(.alreadyPending, "\(target.name) is already waiting to unblock. Keep it blocked first if you want a temporary unblock instead.") }
        if temporaryUnblock(of: target) != nil { throw reject(.alreadyPending, "\(target.name) already has a temporary unblock.") }
        // 5. How long it stays open.
        guard windowSeconds >= policy.minTemporarySeconds else { throw reject(.invalidDuration, "It must stay open for at least \(Formatting.duration(policy.minTemporarySeconds)).") }
        guard windowSeconds <= policy.maxTemporarySeconds else { throw reject(.invalidDuration, "It can't stay open for more than \(Formatting.duration(policy.maxTemporarySeconds)).") }
        // 6. When it opens: never sooner than the unblock delay (a temporary unblock must not be a way around the wait), and not later than the longest start wait. Left out, it opens after the delay.
        let startSeconds = request.startSeconds ?? state.delaySeconds
        guard startSeconds >= state.delaySeconds else { throw reject(.invalidDuration, "It can't open sooner than your unblock delay of \(Formatting.duration(state.delaySeconds)).") }
        guard startSeconds <= policy.maxTemporaryStartSeconds else { throw reject(.invalidDuration, "It can't open later than \(Formatting.duration(policy.maxTemporaryStartSeconds)) from now.") }
        // 7. The password rule: lockout, no password set, wrong password.
        if let denied = checkPassword(password) { return denied }
        // 8. Everything is valid, so the site starts waiting. The countdowns are built first so `state` is only written, not read, in the assignment.
        let unblock = TemporaryUnblock(startsIn: Countdown(seconds: Double(startSeconds)), window: Countdown(seconds: Double(windowSeconds)))
        setTemporaryUnblock(unblock, of: target)
        onTemporaryUnblockEvent?("temporary unblock approved: opens in \(Formatting.duration(startSeconds)) for \(Formatting.duration(windowSeconds))")
        return success("\(target.name) opens in \(Formatting.duration(startSeconds)), for \(Formatting.duration(windowSeconds)), then blocks again.")
    }

    /// Finds the site named in a request, rejecting with invalidDomain when the name is not valid and notBlocked when the site is not on the list.
    private func siteTarget(_ raw: String) throws -> Target {
        let domain = try normalized(raw)
        guard let index = state.blocked.firstIndex(where: { $0.domain == domain }) else { throw reject(.notBlocked, "\(domain) is not blocked.") }
        return Target(isRule: false, index: index, name: domain)
    }

    /// Finds the path rule named in a request, rejecting with invalidDomain or invalidPath when the text is not a valid rule and notBlocked when the rule is not on the list.
    private func ruleTarget(_ raw: String) throws -> Target {
        let rule = try parsedRule(raw)
        let text = PathRuleParser.display(domain: rule.domain, path: rule.path)
        guard let index = pathRuleIndex(rule) else { throw reject(.notBlocked, "\(text) is not blocked.") }
        return Target(isRule: true, index: index, name: text)
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

    /// How long a new uninstall waits: the policy's minimum (48 hours when installed) or the current unblock delay, whichever is longer.
    public var uninstallWaitSeconds: Int { max(policy.minUninstallSeconds, state.delaySeconds) }

    /// Starts the uninstall countdown (see `uninstallWaitSeconds`) after the password check, unless one is already running. An uninstall already waiting keeps its own countdown.
    private func uninstall(_ request: Request) throws -> Response {
        let password = try require(request.password, "password")
        if let denied = checkPassword(password) { return denied }
        if let existing = state.pendingUninstall { return success("Uninstall is already waiting, in \(Formatting.duration(existing.displaySeconds)). You can cancel any time before then.") }
        let wait = uninstallWaitSeconds
        state.pendingUninstall = Countdown(seconds: Double(wait))
        return success("SiteBlock will uninstall in \(Formatting.duration(wait)). Every site stays blocked until then, and you can cancel any time before then.")
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

    /// Moves every temporary unblock forward by the elapsed seconds, on sites and on path rules. Returns true when at least one opened (its start wait ran out) or ended (its window ran out). An ended one is removed and the site or rule stays on the block list.
    private func advanceTemporaryUnblocks(by elapsed: Double) -> Bool {
        var changed = false
        for index in state.blocked.indices {
            // The result is computed before the write, because reading `state` while writing to it in one statement is an overlapping access that Swift stops with a crash.
            let result = advanced(state.blocked[index].temporaryUnblock, by: elapsed)
            if result.changed { changed = true }
            state.blocked[index].temporaryUnblock = result.unblock
        }
        if var rules = state.blockedPaths {
            for index in rules.indices {
                let result = advanced(rules[index].temporaryUnblock, by: elapsed)
                if result.changed { changed = true }
                rules[index].temporaryUnblock = result.unblock
            }
            state.blockedPaths = rules
        }
        return changed
    }

    /// Moves one temporary unblock forward and reports what happened. If the start wait ran out and the window did not, the unblock has opened and is kept. If the window ran out too, the unblock has ended and nil comes back. A gap long enough to cover both the opening and the end (for example a Mac that slept) therefore just ends it, with no "opened" message. Each outcome is sent to `onTemporaryUnblockEvent`. Does nothing for a site with no temporary unblock.
    private func advanced(_ unblock: TemporaryUnblock?, by elapsed: Double) -> (unblock: TemporaryUnblock?, changed: Bool) {
        guard var current = unblock else { return (nil, false) }
        let wasOpen = current.isOpen
        current.advance(by: elapsed)
        if current.isFinished {
            onTemporaryUnblockEvent?("temporary unblock ended; the site is blocked again")
            return (nil, true)
        }
        if current.isOpen, !wasOpen {
            onTemporaryUnblockEvent?("temporary unblock opened")
            return (current, true)
        }
        return (current, false)
    }

    /// Advances every countdown by the elapsed seconds and applies the ones that finished. Returns true when something finished or a temporary unblock opened, meaning the state must be saved now. Negative, NaN or infinite input changes nothing.
    public func tick(elapsed: Double) -> Bool {
        guard elapsed.isFinite, elapsed > 0 else { return false }
        for index in state.blocked.indices { state.blocked[index].pendingUnblock?.advance(by: elapsed) }
        if var rules = state.blockedPaths {
            for index in rules.indices { rules[index].pendingUnblock?.advance(by: elapsed) }
            state.blockedPaths = rules
        }
        state.pendingDelayChange?.countdown.advance(by: elapsed)
        state.pendingUninstall?.advance(by: elapsed)
        state.recovery?.advance(by: elapsed)
        state.lockout?.advance(by: elapsed)

        // The order below matters only in that every finished countdown is applied; sites and path rules go first so the hosts file and the browsers' lists lose them on the next pass.
        // A temporary unblock that opens or ends changes what must be blocked, so it counts as a change to save.
        var changed = advanceTemporaryUnblocks(by: elapsed)
        let siteCount = state.blocked.count
        state.blocked.removeAll { $0.pendingUnblock?.isFinished == true }
        if state.blocked.count != siteCount { changed = true }
        // Path rules whose unblock finished go the same way; the list goes back to nil when the last one leaves, so the saved file looks like one from before path rules existed.
        if let rules = state.blockedPaths {
            let remaining = rules.filter { $0.pendingUnblock?.isFinished != true }
            if remaining.count != rules.count {
                state.blockedPaths = remaining.isEmpty ? nil : remaining
                changed = true
            }
        }

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
