import Foundation
import SiteBlockCore

// Helpers for the temporary unblock integration tests. What the files must hold comes from Design Plans/01-overview-and-data.md § How Blocking Works (Temporary unblock),
// 02-core-components.md § Engine and 03-daemon-cli-app.md § 13 BrowserPolicyEnforcer, through the same `ExpectedHosts` and `designLists` builders the other tests use.

// The sentences the daemon logs for a temporary unblock, typed from 03-daemon-cli-app.md § Daemon Runtime ("Temporary unblock log lines").
enum TemporaryLogLine {
    // "temporary unblock approved: opens in 1 hour for 30 minutes"; the two durations are written the way `Formatting.duration` writes them.
    static func approved(opensIn: String, window: String) -> String { "temporary unblock approved: opens in \(opensIn) for \(window)" }
    static let opened = "temporary unblock opened"
    static let ended = "temporary unblock ended; the site is blocked again"
    static let cancelled = "temporary unblock cancelled"
    static let endedEarly = "temporary unblock ended early"
}

extension SandboxDaemon {
    // Sends temporaryUnblock (or temporaryUnblockPath) through the real socket with the real DaemonClient. A nil field is left out of the request.
    func sendTemporary(_ command: Command = .temporaryUnblock, domain: String?, password: String? = SandboxDaemon.password, seconds: Int?, startSeconds: Int? = nil) throws -> Response {
        try client().send(Request(command: command, domain: domain, password: password, seconds: seconds, startSeconds: startSeconds))
    }

    // The temporary unblock the daemon reports for a site, or nil.
    func temporaryStatus(ofSite domain: String) throws -> TemporaryUnblockStatus? {
        try status().blocked.first { $0.domain == domain }?.temporaryUnblock
    }

    // The temporary unblock the daemon reports for a path rule (given as the rule text, for example youtube.com/shorts), or nil.
    func temporaryStatus(ofRule rule: String) throws -> TemporaryUnblockStatus? {
        try status().blockedPaths?.first { $0.rule == rule }?.temporaryUnblock
    }

    // True when every browser policy file the design lists holds exactly the content for these block lists (the design's filter keys with their types, plus the list, left out when empty).
    func browserFilesHold(_ lists: (chrome: [String], firefox: [String])) -> Bool {
        guard let files = try? browserFiles() else { return false }
        return files.refs.allSatisfy { ref in
            guard let path = files.path(ref) else { return false }
            return fileIsRight(path, ref.browser.expected(list: ref.browser.pick(lists)))
        }
    }

    // What the hosts file must hold while exactly these sites are blocked (the sites that are not open): the user's own lines, then the managed section for their expansions.
    func hostsExpected(blocking domains: [String]) -> String {
        ExpectedHosts.text(blocking: ExpectedHosts.expand(all: domains))
    }

    // The value of a number in the saved state file at a path of keys and array positions, or nil.
    func stateNumber(_ path: [Any]) -> Double? {
        var current: Any? = stateObject()
        for step in path {
            if let key = step as? String { current = (current as? NSDictionary)?[key] } else if let index = step as? Int, let list = current as? NSArray, index < list.count { current = list[index] } else { return nil }
        }
        return (current as? NSNumber)?.doubleValue
    }
}
