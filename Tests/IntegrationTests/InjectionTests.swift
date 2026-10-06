import Foundation
import SiteBlockCore
import Testing

// Hostile domain strings sent as raw JSON over the real socket. The hosts file must never gain a line for anything but a clean host name.
// Design: 05-testing-and-operations.md § Security Considerations ("Domain strings are validated to a-z 0-9 - . before they reach the hosts file"); 02-core-components.md § DomainNormalizer.
@Suite("Domain injection")
struct InjectionTests {
    // Sends `add` with the domain string as raw JSON and returns the reply.
    static func rawAdd(_ domain: String, to daemon: SandboxDaemon) throws -> RawReply {
        try rawExchange(try requestLine(["command": "add", "domain": domain]), socketPath: daemon.socketPath)
    }

    // Strings that must be refused: after trimming the ends, an ASCII space, tab, newline or other character outside a-z 0-9 - . is left inside a label, or the name is an IP address, a reserved name, empty, or breaks a length rule.
    static let mustReject: [String] = [
        "evil.com\n0.0.0.0 bank.com",
        "evil.com\r\n0.0.0.0 bank.com",
        "evil.com 0.0.0.0 bank.com",
        "evil.com bank.com",
        "evil .com",
        "ev il.com",
        "evil.co m",
        "evil.com\t0.0.0.0\tbank.com",
        "evil.com\u{0B}0.0.0.0 bank.com",
        "evil.com\u{0C}0.0.0.0 bank.com",
        "evil\u{0}.com",
        "evil.com\u{0}",
        "# END SiteBlock",
        "#evil.com",
        "-evil.com",
        "evil-.com",
        "evil..com",
        ".evil.com",
        "evil_x.com",
        "ev!l.com",
        "evil.com,bank.com",
        "evil.com;bank.com",
        "evil.com|bank.com",
        "evil.com&bank.com",
        "$(whoami).com",
        "`id`.com",
        "evil.com\\nbank.com",
        "*.evil.com",
        "evil.*",
        "<script>.com",
        "evil.com\"",
        "evil'.com",
        "%0a.com",
        "evil.com%0a0.0.0.0%20bank.com",
        "1.2.3.4",
        "127.0.0.1",
        "0.0.0.0",
        "[::1]",
        "::1",
        "localhost",
        "foo.local",
        "foo.localhost",
        "evil",
        "",
        "   ",
        "\n\n",
        String(repeating: "a", count: 64) + ".com",
        ([String(repeating: "a", count: 63), String(repeating: "a", count: 63), String(repeating: "a", count: 63), String(repeating: "a", count: 58), "com"]).joined(separator: "."),
    ]

    // 05 Security Considerations: none of the refused strings reaches the hosts file or the saved state, and every one gets invalidDomain.
    @Test func invalidOrNewlineBearingDomainsAreRefusedAndNeverTouchTheHostsFile() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            for payload in Self.mustReject {
                let reply = try Self.rawAdd(payload, to: daemon)
                #expect(reply.ok == false, "accepted: \(payload.debugDescription) -> \(reply.text.prefix(200))")
                #expect(reply.errorCode == "invalidDomain", "\(payload.debugDescription) got \(String(describing: reply.errorCode))")
                #expect(daemon.hostsText() == StandardHosts.text, "hosts file changed after \(payload.debugDescription)")
            }
            pause(0.5)
            #expect(daemon.hostsText() == StandardHosts.text)
            let status = try daemon.status()
            #expect(status.blocked.isEmpty)
            let saved = try #require(daemon.stateObject())
            #expect((saved["blocked"] as? [Any])?.isEmpty == true)
        }
    }

    // Strings where the design's own rules decide the outcome in a way the design does not spell out for every character (the cut at # / ? and the port rule, trailing separators, non-ASCII separators that become Punycode). Whatever the daemon decides, the hosts file may only gain clean host lines for clean host names, and nothing from after the separator.
    static let hostile: [String] = [
        "evil.com#0.0.0.0 bank.com",
        "evil.com # 0.0.0.0 bank.com",
        "evil.com#",
        "evil.com/../../etc/hosts",
        "evil.com?x=\n0.0.0.0 bank.com",
        "http://evil.com/path\n0.0.0.0 bank.com",
        "evil.com:80\n0.0.0.0 bank.com",
        "evil.com\n:: bank.com",
        "evil.com :: bank.com",
        "evil.com\u{2028}bank.com",
        "evil.com\u{85}bank.com",
        "evil.com\u{A0}bank.com",
        "evil.com\u{200B}bank.com",
        "evil.com\u{FF0E}bank.com",
        "evil.com\u{202E}moc.knab",
    ]

    // The strict shape of a line inside the managed section: an address, one space, one clean host name.
    static let managedLinePattern = try! NSRegularExpression(pattern: "^(0\\.0\\.0\\.0|::) [a-z0-9]([a-z0-9.-]*[a-z0-9])?$")

    // True when the managed line has exactly the strict shape.
    static func isCleanManagedLine(_ line: String) -> Bool {
        managedLinePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    // 05 Security Considerations: whatever happens to the awkward strings, the hosts file keeps its macOS lines, the section has only clean `address host` lines, and bank.com (the second host an attacker tried to smuggle in) is never blocked.
    @Test func awkwardDomainsNeverInjectExtraLinesOrSmuggleASecondHost() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            var accepted: [String] = []
            for payload in Self.hostile {
                let reply = try Self.rawAdd(payload, to: daemon)
                // Three outcomes are fine: refused as invalid, accepted as a clean domain, or (when an earlier string already normalized to the same domain) alreadyBlocked.
                if reply.ok == true { accepted.append(payload) } else { #expect(["invalidDomain", "alreadyBlocked"].contains(reply.errorCode ?? "none"), "\(payload.debugDescription): \(reply.text.prefix(200))") }
            }
            pause(0.6)
            let text = daemon.hostsText()
            let view = HostsView(text)
            let outside = text.components(separatedBy: "\n").filter { line in !view.managedLines.contains(line) && !line.hasPrefix("# BEGIN SiteBlock") && line != ExpectedHosts.endMarker }
            #expect(view.beginCount <= 1 && view.endCount <= 1)
            #expect(outside.filter { !$0.isEmpty } == StandardHosts.text.components(separatedBy: "\n").filter { !$0.isEmpty }, "lines outside the section changed:\n\(text)")
            for line in view.managedLines { #expect(Self.isCleanManagedLine(line), "unclean line in the section: \(line.debugDescription)") }
            let hostNames = Set(view.managedLines.compactMap { $0.split(separator: " ").last.map(String.init) })
            #expect(!hostNames.contains("bank.com") && !hostNames.contains("www.bank.com"), "bank.com was smuggled in: \(accepted.map { $0.debugDescription })")
            let status = try daemon.status()
            for site in status.blocked {
                #expect(site.domain.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil, "unclean blocked domain \(site.domain.debugDescription)")
                #expect(site.domain != "bank.com")
            }
            // Everything in the hosts file belongs to a domain the daemon reports as blocked.
            #expect(hostNames == Set(ExpectedHosts.expand(all: status.blocked.map(\.domain))))
        }
    }

    // 02 § DomainNormalizer steps 1 and 3: surrounding whitespace is trimmed and a user:password@ prefix is dropped, so these two strings are real requests for bank.com, and only bank.com's own hosts appear.
    @Test(arguments: ["bank.com\n", "  bank.com \t\n", "evil.com@bank.com"])
    func trimmedAndUserInfoFormsBlockOnlyTheRealHost(input: String) throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let reply = try Self.rawAdd(input, to: daemon)
            #expect(reply.ok == true, "\(input.debugDescription): \(reply.text.prefix(200))")
            #expect((reply.json?["status"] as? [String: Any])?["blocked"] is [[String: Any]])
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand("bank.com")))
            #expect(!daemon.hostsText().contains("evil.com"))
        }
    }

    // 02 § DomainNormalizer: the many ways of typing a site all block the same base domain, and the hosts file gets exactly that domain's expansion.
    @Test(arguments: [
        ("https://www.reddit.com/r/all?x=1#top", "reddit.com"),
        ("HTTPS://WWW.Reddit.COM/", "reddit.com"),
        ("REDDIT.COM.", "reddit.com"),
        ("user:pw@reddit.com:8443/x", "reddit.com"),
        ("www.reddit.com", "reddit.com"),
        ("bücher.de", "xn--bcher-kva.de"),
        ("münchen.de", "xn--mnchen-3ya.de"),
    ])
    func differentSpellingsBlockTheSameBaseDomain(input: String, base: String) throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let reply = try Self.rawAdd(input, to: daemon).json
            #expect(reply?["ok"] as? Bool == true, "\(input): \(String(describing: reply))")
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == [base])
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand(base)))
        }
    }

    // 01 § Wire Protocol: a raw newline inside the JSON text ends the request, so the first line is truncated JSON (badRequest) and the rest of the "request" is never read as a second command.
    @Test func aRawNewlineInsideTheDomainEndsTheRequestAndTheRestIsIgnored() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let reply = try rawExchange("{\"command\":\"add\",\"domain\":\"evil.com\n0.0.0.0 bank.com\"}\n", socketPath: daemon.socketPath)
            #expect(reply.errorCode == "badRequest", "got: \(reply.text.prefix(200))")
            pause(0.5)
            #expect(daemon.hostsText() == StandardHosts.text)
            let status = try daemon.status()
            #expect(status.blocked.isEmpty)
        }
    }

    // 01 § Wire Protocol: an add with no domain, a null domain, or a domain of the wrong type is refused and changes nothing. The design does not say whether the code is badRequest or invalidDomain, so either is accepted.
    @Test(arguments: ["{\"command\":\"add\"}\n", "{\"command\":\"add\",\"domain\":null}\n", "{\"command\":\"add\",\"domain\":\"\"}\n", "{\"command\":\"add\",\"domain\":12}\n"])
    func addWithoutAUsableDomainIsRefusedAndChangesNothing(request: String) throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let reply = try rawExchange(request, socketPath: daemon.socketPath)
            #expect(reply.ok == false, "\(request.debugDescription): \(reply.text.prefix(200))")
            #expect(["badRequest", "invalidDomain"].contains(reply.errorCode ?? "none"), "got \(String(describing: reply.errorCode))")
            #expect(daemon.hostsText() == StandardHosts.text)
        }
    }

    // 02 § DomainNormalizer step 6: sizes are checked on the raw Unicode scalars before any Punycode encoding, because encoding time grows with the square of the label length. A 30,000-character non-ASCII label (a request of about 60 KB, under the size limit) must be refused at once, and other clients must not have to wait for it.
    @Test func aHugeNonAsciiLabelIsRefusedQuicklyAndDoesNotStallOtherClients() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let request = try requestLine(["command": "add", "domain": String(repeating: "ü", count: 30_000) + ".com"])
            try require(request.utf8.count < 65_000, "the request must stay under the 64 KB limit to reach the normalizer")
            let replies = WireProtocolTests.concurrently(2, inFlight: 2) { _ -> (RawReply?, Double) in
                let watch = Stopwatch()
                let reply = try? rawExchange(request, socketPath: daemon.socketPath)
                return (reply, watch.elapsed)
            }
            for (reply, seconds) in replies {
                #expect(reply?.errorCode == "invalidDomain", "got: \(reply?.text.prefix(200) ?? "no reply")")
                #expect(seconds < 1.0, "the huge label took \(seconds) s to refuse")
            }
            let probe = Stopwatch()
            let status = try daemon.status()
            #expect(status.blocked.isEmpty)
            #expect(probe.elapsed < 1.0)
            let small = try Self.rawAdd(String(repeating: "ü", count: 64) + ".com", to: daemon)
            #expect(small.errorCode == "invalidDomain", "a 64-character non-ASCII label is over the 63-scalar limit: \(small.text.prefix(200))")
        }
    }
}
