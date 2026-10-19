import Foundation
import Testing
import SiteBlockCore

// Shared helpers for the temporary unblock tests. Expected values in those tests come from Design Plans/01-overview-and-data.md § Data Model
// (TemporaryUnblock), § Wire Protocol, § Fixed Policy Values and 02-core-components.md § Engine (Temporary unblock commands, tick rule, status),
// never from reading the implementation.

// The design's fixed policy numbers with the three temporary unblock limits written out: a window of 300 to 14400 seconds and a start wait of at most
// 604800 seconds (01 § Fixed Policy Values). They are typed here on purpose, so a change of the initializer's defaults cannot hide behind a test.
let temporaryPolicy = Policy(defaultDelaySeconds: 1800, minDelaySeconds: 60, maxDelaySeconds: 604_800, recoverySeconds: 172_800, lockoutSeconds: 900, maxFailedAttempts: 5, pbkdf2Iterations: 1000, maxSites: 500, minUninstallSeconds: 172_800, minTemporarySeconds: 300, maxTemporarySeconds: 14_400, maxTemporaryStartSeconds: 604_800)

// The same policy with a different default unblock delay, which is the delay a fresh engine starts with.
func policyWithDelay(_ delay: Int) -> Policy {
    var policy = temporaryPolicy
    policy.defaultDelaySeconds = delay
    return policy
}

extension Engine {
    // Sends temporaryUnblock (or temporaryUnblockPath when `rule` is true) the way the daemon would. The defaults are a valid request for reddit.com
    // with the right password; a test that wants a field missing passes nil for it explicitly.
    @discardableResult
    func temporarily(_ domain: String? = "reddit.com", password: String? = rightPassword, seconds: Int? = 1800, start: Int? = nil, rule: Bool = false, uid: uid_t = 501) -> Response {
        handle(Request(command: rule ? .temporaryUnblockPath : .temporaryUnblock, domain: domain, password: password, seconds: seconds, startSeconds: start), peerUID: uid)
    }

    // The blocked site with this domain, if any.
    func site(_ domain: String) -> BlockedSite? { state.blocked.first { $0.domain == domain } }

    // The path rule with this domain and path, if any.
    func pathRule(_ domain: String, _ path: String) -> BlockedPath? { state.blockedPaths?.first { $0.domain == domain && $0.path == path } }

    // The temporary unblock of a site, if it has one.
    func temporaryUnblock(of domain: String) -> TemporaryUnblock? { site(domain)?.temporaryUnblock }

    // The temporary unblock of a path rule, if it has one.
    func temporaryUnblock(ofRule domain: String, _ path: String) -> TemporaryUnblock? { pathRule(domain, path)?.temporaryUnblock }

    // The status the engine reports for a site's temporary unblock, read through the real status command.
    func temporaryStatus(of domain: String) -> TemporaryUnblockStatus? {
        send(.status).status?.blocked.first { $0.domain == domain }?.temporaryUnblock
    }

    // The status the engine reports for a path rule's temporary unblock.
    func temporaryStatus(ofRule rule: String) -> TemporaryUnblockStatus? {
        send(.status).status?.blockedPaths?.first { $0.rule == rule }?.temporaryUnblock
    }
}

// Collects the sentences the engine hands to `onTemporaryUnblockEvent`, in order.
final class EventRecorder {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
}

// Hooks a recorder onto the engine's temporary unblock events and returns it.
func recordEvents(of engine: Engine) -> EventRecorder {
    let recorder = EventRecorder()
    engine.onTemporaryUnblockEvent = { recorder.add($0) }
    return recorder
}

// The sentences 03-daemon-cli-app.md § Daemon Runtime ("Temporary unblock log lines") lists for the five events, typed from the design. The approved line
// carries the start wait and the window written by `Formatting.duration`, so it is built from two ready-made phrases.
func approvedLine(opensIn: String, window: String) -> String { "temporary unblock approved: opens in \(opensIn) for \(window)" }
let openedLine = "temporary unblock opened"
let endedLine = "temporary unblock ended; the site is blocked again"
let cancelledLine = "temporary unblock cancelled"
let endedEarlyLine = "temporary unblock ended early"

// Every "<number> <unit>" phrase in a sentence, in order, with the unit in the singular ("5 minute", "4 hour"). Searching for "5 minutes" in a sentence
// that says "15 minutes" would succeed by accident, so wording tests compare these pairs instead of substrings.
func durationPairs(in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9])([0-9]+) (day|hour|minute|second)s?\b"#) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
        guard let number = Range(match.range(at: 1), in: text), let unit = Range(match.range(at: 2), in: text) else { return nil }
        return "\(text[number]) \(text[unit])"
    }
}

// A small deterministic random number generator (SplitMix64), so generated test sequences are the same on every run and a failure can be replayed from its seed.
struct FuzzGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// An engine with a password, three sites and three path rules, set up through the real commands: a plain one, one waiting for a permanent unblock and one
// with a temporary unblock waiting to open (start wait 3600 s, window 1800 s). The rules are on other domains than the sites so that addPath accepts them.
let scenarioSites = ["plain.example", "pending.example", "temp.example"]
let scenarioRules = ["ruleplain.example/shorts", "rulepending.example/shorts", "ruletemp.example/shorts"]
func makeScenarioEngine(policy: Policy = temporaryPolicy) -> Engine {
    let engine = makeEngine(blocking: scenarioSites, policy: policy)
    for rule in scenarioRules { expectSuccess(engine.send(.addPath, domain: rule)) }
    expectSuccess(engine.send(.unblock, domain: "pending.example", password: rightPassword))
    expectSuccess(engine.send(.unblockPath, domain: "rulepending.example/shorts", password: rightPassword))
    expectSuccess(engine.temporarily("temp.example", seconds: 1800, start: 3600))
    expectSuccess(engine.temporarily("ruletemp.example/shorts", seconds: 1800, start: 3600, rule: true))
    return engine
}

// Schedules a temporary unblock with the default start wait (the current delay) and ticks exactly to the moment it opens, so the site is open with its
// whole window left. Returns the window length so a test can say how much is left.
@discardableResult
func openTemporaryUnblock(_ engine: Engine, _ domain: String = "reddit.com", window: Int = 1800, rule: Bool = false) -> Int {
    expectSuccess(engine.temporarily(domain, seconds: window, rule: rule))
    #expect(engine.tick(elapsed: Double(engine.state.delaySeconds)), "the tick that opens a temporary unblock must report a change to save")
    return window
}
