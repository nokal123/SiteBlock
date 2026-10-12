import Foundation
import Testing
import SiteBlockCore

// Shared helpers for the Engine tests. Expected values in those tests come from Design Plans/02-core-components.md § Engine
// and 01-overview-and-data.md § Commands and § Fixed Policy Values.

// The design's fixed policy numbers (30-minute delay, 60 s to 7 days range, 48 h recovery, 15-minute lockout after 5 wrong
// passwords, at least 48 h before an uninstall) with only the password hashing cost lowered so that tests run fast. Every other value
// is the real one. The uninstall minimum is written out on purpose: 01-overview-and-data.md § Fixed Policy Values says an uninstall waits
// 172800 s or the unblock delay, whichever is longer, and a value left to the initializer's default would hide a change of that default.
let designPolicy = Policy(defaultDelaySeconds: 1800, minDelaySeconds: 60, maxDelaySeconds: 604_800, recoverySeconds: 172_800, lockoutSeconds: 900, maxFailedAttempts: 5, pbkdf2Iterations: 1000, minUninstallSeconds: 172_800)

// The design policy with the uninstall minimum lowered to 60 s, the smallest delay the design allows. Design change: an uninstall now waits
// max(policy.minUninstallSeconds, delaySeconds) (01-overview-and-data.md § Commands (uninstall) and § Fixed Policy Values; 02-core-components.md
// § Engine, Properties and the uninstall command rule). Under this policy the minimum is never the longer of the two, because no delay is
// below 60 s, so an uninstall waits exactly as long as the unblock delay. The tests written before the 48 hour minimum existed only needed an
// uninstall of a size they could tick through (1800 s for the default delay), and they use this policy to keep that setup unchanged.
let shortUninstallPolicy: Policy = {
    var policy = designPolicy
    policy.minUninstallSeconds = 60
    return policy
}()

let rightPassword = "hunter22"
let badPassword = "not-the-password"

// Builds an engine in the state of a new install; with a password it also runs the real setup command first.
func makeEngine(password: String? = rightPassword, policy: Policy = designPolicy) -> Engine {
    let engine = Engine(state: PersistedState.fresh(delaySeconds: policy.defaultDelaySeconds), policy: policy)
    if let password {
        let response = engine.send(.setup, password: password)
        #expect(response.ok, "test setup failed: \(response.error ?? "no error text")")
    }
    return engine
}

// Builds an engine with a password and the given sites blocked.
func makeEngine(blocking domains: [String], policy: Policy = designPolicy) -> Engine {
    let engine = makeEngine(policy: policy)
    for domain in domains {
        let response = engine.send(.add, domain: domain)
        #expect(response.ok, "test setup could not add \(domain): \(response.error ?? "no error text")")
    }
    return engine
}

extension Engine {
    // Sends one command to the engine the way the daemon does; peerUID defaults to an ordinary user.
    @discardableResult
    func send(_ command: Command, domain: String? = nil, password: String? = nil, newPassword: String? = nil, seconds: Int? = nil, uid: uid_t = 501) -> Response {
        handle(Request(command: command, domain: domain, password: password, newPassword: newPassword, seconds: seconds), peerUID: uid)
    }

    // Runs tick(elapsed:) the given number of times and returns how many of those ticks reported a change to save.
    @discardableResult
    func tick(_ elapsed: Double, times: Int) -> Int {
        var saves = 0
        for _ in 0..<times where tick(elapsed: elapsed) { saves += 1 }
        return saves
    }

    // The pending unblock countdown of the blocked site with the given domain, if any.
    func pendingUnblock(of domain: String) -> Countdown? {
        state.blocked.first { $0.domain == domain }?.pendingUnblock
    }
}

// Checks that a response is a failure with the given code and a non-empty human sentence.
func expectFailure(_ response: Response, _ code: ErrorCode, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(response.ok == false, sourceLocation: sourceLocation)
    #expect(response.errorCode == code, "expected \(code), got \(String(describing: response.errorCode)): \(response.error ?? "")", sourceLocation: sourceLocation)
    #expect(!(response.error ?? "").isEmpty, "a failure must carry a readable sentence", sourceLocation: sourceLocation)
}

// Checks that a response is a success that carries a status snapshot.
func expectSuccess(_ response: Response, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(response.ok == true, "expected success, got \(String(describing: response.errorCode)): \(response.error ?? "")", sourceLocation: sourceLocation)
    #expect(response.status != nil, "a success must carry a status snapshot", sourceLocation: sourceLocation)
}

// Sends five wrong passwords through unblock and returns the responses, which locks the engine out.
@discardableResult
func exhaustPasswordAttempts(_ engine: Engine, domain: String = "reddit.com") -> [Response] {
    (0..<engine.policy.maxFailedAttempts).map { _ in engine.send(.unblock, domain: domain, password: badPassword) }
}

// The names the hosts file always blocks while SiteBlock is installed, typed from the design and not read from the code: the two iCloud Private
// Relay names (02-core-components.md § Engine, `privateRelayHosts`) and the four DNS-over-HTTPS names browsers use by default (02 § Engine,
// `dohBypassHosts`; 01-overview-and-data.md § How Blocking Works, "Other browsers"). `hostsToWrite` is the blocked hosts plus all six, sorted.
let designPrivateRelayHosts = ["mask-h2.icloud.com", "mask.icloud.com"]
let designDoHBypassHosts = ["doh.xfinity.com", "firefox.dns.nextdns.io", "mozilla.cloudflare-dns.com", "private.canadianshield.cira.ca"]
let designAlwaysWrittenHosts = (designPrivateRelayHosts + designDoHBypassHosts).sorted()
