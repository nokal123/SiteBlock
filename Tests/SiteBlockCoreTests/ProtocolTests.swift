import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/01-overview-and-data.md § Wire Protocol (Request, Response, StatusSnapshot, Commands,
// error codes) and 02-core-components.md § Models and Protocol Types ("JSON uses the default JSONEncoder with .sortedKeys,
// field names exactly as written in the design").

// The wire format: one JSON object per message, with keys in sorted order.
private func json(_ value: some Encodable) throws -> String {
    String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self)
}

private func decodeRequest(_ text: String) throws -> Request {
    try JSONCoding.decoder.decode(Request.self, from: Data(text.utf8))
}

@Suite struct ProtocolTests {
    // Design change: 01-overview-and-data.md § Commands now lists 15 commands, not 12. The three additions are `addPath`, `unblockPath` and
    // `cancelUnblockPath` (path rules, which block part of a site). The expected set is typed from the design's current list.
    @Test func theCommandNamesOnTheWireAreExactlyTheDesignsFifteen() {
        let expected: Set<String> = ["status", "setup", "add", "unblock", "cancelUnblock", "addPath", "unblockPath", "cancelUnblockPath", "setDelay", "cancelDelayChange", "changePassword", "uninstall", "cancelUninstall", "recoveryStart", "recoveryCancel"]
        #expect(Set(Command.allCases.map(\.rawValue)) == expected)
        #expect(Command.allCases.count == 15)
    }

    // Design change: 01-overview-and-data.md § Response now lists 15 error codes, not 13. The two additions are `notAllowed` (setup
    // refused for a caller who is neither root nor the console user) and `tooManySites` (an add beyond the site cap). The earlier
    // version of this test pinned the 13-code list, so against the current design it would have reported the two new, correct
    // codes as a defect. The expected set below is typed from the design's current list, not read from the enum.
    // Design change: 01-overview-and-data.md § Response now lists 16 error codes. The addition is `invalidPath` (the path part of a path rule
    // cannot be used, or the text has no path at all).
    @Test func theErrorCodesOnTheWireAreExactlyTheDesignsSixteen() {
        let expected: Set<String> = ["badRequest", "invalidDomain", "notSetUp", "alreadySetUp", "wrongPassword", "lockedOut", "weakPassword", "notBlocked", "alreadyBlocked", "nothingPending", "invalidDelay", "notRoot", "notAllowed", "tooManySites", "invalidPath", "internal"]
        #expect(Set(ErrorCode.allCases.map(\.rawValue)) == expected)
        #expect(ErrorCode.allCases.count == 16)
    }

    @Test func aRequestEncodesToOneLineOfSortedKeyJSONAndSkipsUnusedFields() throws {
        #expect(try json(Request(command: .add, domain: "reddit.com")) == #"{"command":"add","domain":"reddit.com"}"#)
        #expect(try json(Request(command: .status)) == #"{"command":"status"}"#)
        #expect(try json(Request(command: .changePassword, domain: "d", password: "p", newPassword: "n", seconds: 5)) == #"{"command":"changePassword","domain":"d","newPassword":"n","password":"p","seconds":5}"#)
    }

    @Test func aRequestWrittenByHandFromTheDesignDecodes() throws {
        #expect(try decodeRequest(#"{"command":"setDelay","seconds":120,"password":"x"}"#) == Request(command: .setDelay, password: "x", seconds: 120))
        #expect(try decodeRequest(#"{"command":"unblock","domain":"reddit.com","password":"pw"}"#) == Request(command: .unblock, domain: "reddit.com", password: "pw"))
        #expect(try decodeRequest(#"{"command":"status"}"#) == Request(command: .status))
        #expect(try decodeRequest(#"{"command":"changePassword","password":"a","newPassword":"b"}"#) == Request(command: .changePassword, password: "a", newPassword: "b"))
    }

    // The daemon turns a decode failure into badRequest, so each of these must fail to decode rather than become some command.
    @Test(arguments: [
        #"{"command":"explode"}"#, #"{}"#, #"{"domain":"reddit.com"}"#, #"{"command":42}"#, #"{"command":null}"#, #"{"command":"add","domain":5}"#,
        #"{"command":"setDelay","seconds":"soon"}"#, #"{"command":"setDelay","seconds":1.5}"#, #"["add"]"#, "not json", "", #"{"command":"ADD"}"#, #"{"command":"add""#,
    ])
    func aMalformedRequestFailsToDecode(text: String) {
        #expect(throws: (any Error).self) { try decodeRequest(text) }
    }

    @Test func aRequestIgnoresFieldsItDoesNotKnow() throws {
        #expect(try decodeRequest(#"{"command":"status","futureField":[1,2,3]}"#) == Request(command: .status))
    }

    // The wire is one JSON object per line, so a newline or control character in a value must be escaped, never written raw.
    @Test func aRequestWithNewlinesInItsValuesStaysOnOneLine() throws {
        let line = try json(Request(command: .add, domain: "a\nb\r\nc\u{2028}d", password: "p\tq\u{0}"))
        #expect(!line.contains("\n") && !line.contains("\r"))
        let decoded = try decodeRequest(line)
        #expect(decoded.domain == "a\nb\r\nc\u{2028}d")
        #expect(decoded.password == "p\tq\u{0}")
    }

    @Test func everyRequestRoundTripsThroughJSON() throws {
        for command in Command.allCases {
            let request = Request(command: command, domain: "b\u{FC}cher.de", password: "p\u{E4}ss \"quoted\" \\ back", newPassword: "\u{1F600}", seconds: -5)
            #expect(try decodeRequest(try json(request)) == request)
        }
    }

    @Test func aFailureResponseEncodesWithTheDesignsFieldNames() throws {
        #expect(try json(Response.failure(.wrongPassword, "Nope.")) == #"{"error":"Nope.","errorCode":"wrongPassword","ok":false}"#)
        let failure = Response.failure(.lockedOut, "Locked.")
        #expect(failure.ok == false && failure.error == "Locked." && failure.errorCode == .lockedOut && failure.status == nil && failure.message == nil)
    }

    // Design change: 01-overview-and-data.md § StatusSnapshot added `adultFilterEnabled`, which a daemon that has the adult content filter always sends as true. The sample is a snapshot from such a daemon, so the exact-JSON tests below include the new key.
    // Design change: the same section added `blockedPaths` (each rule with domain, path, rule and unblockSecondsRemaining). The sample holds one rule with a pending unblock and one without, so the exact-JSON tests below pin the shape of both.
    private static func sampleStatus() -> StatusSnapshot {
        StatusSnapshot(version: "1.0.0", passwordSet: true, blocked: [BlockedSiteStatus(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"], unblockSecondsRemaining: 1800), BlockedSiteStatus(domain: "example.com", hosts: ["example.com"], unblockSecondsRemaining: nil)], delaySeconds: 1800, pendingDelay: PendingDelayStatus(newDelaySeconds: 600, secondsRemaining: 1700), uninstallSecondsRemaining: 10, recoverySecondsRemaining: 20, lockoutSecondsRemaining: 30, hostsFileHealthy: true, adultFilterEnabled: true, blockedPaths: [BlockedPathStatus(domain: "youtube.com", path: "/shorts", rule: "youtube.com/shorts", unblockSecondsRemaining: 900), BlockedPathStatus(domain: "x.com", path: "/Home", rule: "x.com/Home", unblockSecondsRemaining: nil)])
    }

    @Test func aSuccessResponseCarriesTheStatusAndTheMessage() throws {
        let response = Response.success(status: Self.sampleStatus(), message: "reddit.com will unblock in 30 minutes.")
        #expect(response.ok == true && response.error == nil && response.errorCode == nil)
        #expect(response.message == "reddit.com will unblock in 30 minutes.")
        #expect(response.status == Self.sampleStatus())
        let decoded = try JSONCoding.decoder.decode(Response.self, from: try JSONCoding.encoder.encode(response))
        #expect(decoded == response)
    }

    @Test func theStatusSnapshotUsesExactlyTheFieldNamesFromTheDesign() throws {
        let data = try JSONCoding.encoder.encode(Self.sampleStatus())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "passwordSet", "blocked", "delaySeconds", "pendingDelay", "uninstallSecondsRemaining", "recoverySecondsRemaining", "lockoutSecondsRemaining", "hostsFileHealthy", "adultFilterEnabled", "blockedPaths"])
        let sites = try #require(object["blocked"] as? [[String: Any]])
        let site = try #require(sites.first)
        #expect(Set(site.keys) == ["domain", "hosts", "unblockSecondsRemaining"])
        let rules = try #require(object["blockedPaths"] as? [[String: Any]])
        #expect(Set(try #require(rules.first).keys) == ["domain", "path", "rule", "unblockSecondsRemaining"])
        #expect(Set((object["pendingDelay"] as? [String: Any])?.keys.map { $0 } ?? []) == ["newDelaySeconds", "secondsRemaining"])
        #expect(try JSONCoding.decoder.decode(StatusSnapshot.self, from: data) == Self.sampleStatus())
    }

    @Test func aSnapshotWithNothingRunningOmitsTheOptionalCountdownFields() throws {
        let idle = StatusSnapshot(version: "1.0.0", passwordSet: false, blocked: [], delaySeconds: 1800, pendingDelay: nil, uninstallSecondsRemaining: nil, recoverySecondsRemaining: nil, lockoutSecondsRemaining: nil, hostsFileHealthy: true)
        let object = try #require(try JSONSerialization.jsonObject(with: try JSONCoding.encoder.encode(idle)) as? [String: Any])
        for key in ["pendingDelay", "uninstallSecondsRemaining", "recoverySecondsRemaining", "lockoutSecondsRemaining"] { #expect(object[key] == nil || object[key] is NSNull, "\(key) should be absent or null when idle") }
        #expect(try JSONCoding.decoder.decode(StatusSnapshot.self, from: try JSONCoding.encoder.encode(idle)) == idle)
    }

    @Test func aResponseFromAnEngineCommandRoundTripsThroughTheWire() throws {
        let engine = makeEngine(blocking: ["reddit.com"])
        for response in [engine.send(.status), engine.send(.unblock, domain: "reddit.com", password: rightPassword), engine.send(.unblock, domain: "reddit.com", password: badPassword), engine.send(.add, domain: "1.2.3.4")] {
            let data = try JSONCoding.encoder.encode(response)
            #expect(!data.contains(0x0A), "a response must be a single line")
            #expect(try JSONCoding.decoder.decode(Response.self, from: data) == response)
        }
    }

    // MARK: the success response, byte for byte

    // The smallest successful reply. 01-overview-and-data.md § Response: `ok` and `status` are the only fields a bare success must
    // carry; `error`, `errorCode` and `message` are optional. The wire format is the default encoder with sorted keys, so a nil
    // optional is left out entirely (never written as null) and every object lists its keys alphabetically.
    @Test func aMinimalSuccessResponseEncodesToExactlyTheDesignsJSON() throws {
        let idle = StatusSnapshot(version: "1.0.0", passwordSet: false, blocked: [], delaySeconds: 1800, pendingDelay: nil, uninstallSecondsRemaining: nil, recoverySecondsRemaining: nil, lockoutSecondsRemaining: nil, hostsFileHealthy: true, adultFilterEnabled: true)
        // Design change: a snapshot built with the default `blockedPaths` (an empty list) writes `"blockedPaths":[]`, because a daemon that has path rules always sends the list.
        let statusJSON = #"{"adultFilterEnabled":true,"blocked":[],"blockedPaths":[],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":false,"version":"1.0.0"}"#
        #expect(try json(Response.success(status: idle)) == #"{"ok":true,"status":"# + statusJSON + "}")
        #expect(try json(Response.success(status: idle, message: "Password set.")) == #"{"message":"Password set.","ok":true,"status":"# + statusJSON + "}")
    }

    // A success with every optional field filled in, written out by hand from the design's field names in sorted order. Foundation's JSON encoder writes a forward slash as "\/" (a legal JSON escape that every decoder reads back as "/"), so the path rules' "/shorts" appears as "\/shorts".
    @Test func aFullSuccessResponseEncodesToExactlyTheDesignsJSON() throws {
        let response = Response.success(status: Self.sampleStatus(), message: "reddit.com will unblock in 30 minutes.")
        let expected = #"{"message":"reddit.com will unblock in 30 minutes.","ok":true,"status":{"adultFilterEnabled":true,"blocked":[{"domain":"reddit.com","hosts":["reddit.com","www.reddit.com"],"unblockSecondsRemaining":1800},{"domain":"example.com","hosts":["example.com"]}],"blockedPaths":[{"domain":"youtube.com","path":"\/shorts","rule":"youtube.com\/shorts","unblockSecondsRemaining":900},{"domain":"x.com","path":"\/Home","rule":"x.com\/Home"}],"delaySeconds":1800,"hostsFileHealthy":true,"lockoutSecondsRemaining":30,"passwordSet":true,"pendingDelay":{"newDelaySeconds":600,"secondsRemaining":1700},"recoverySecondsRemaining":20,"uninstallSecondsRemaining":10,"version":"1.0.0"}}"#
        #expect(try json(response) == expected)
    }

    // The same JSON typed by hand must decode into the matching values, so a client written from the design alone can read replies.
    @Test func aSuccessResponseWrittenByHandFromTheDesignDecodes() throws {
        let text = #"{"message":"reddit.com will unblock in 30 minutes.","ok":true,"status":{"adultFilterEnabled":true,"blocked":[{"domain":"reddit.com","hosts":["reddit.com","www.reddit.com"],"unblockSecondsRemaining":1800},{"domain":"example.com","hosts":["example.com"]}],"blockedPaths":[{"domain":"youtube.com","path":"\/shorts","rule":"youtube.com\/shorts","unblockSecondsRemaining":900},{"domain":"x.com","path":"\/Home","rule":"x.com\/Home"}],"delaySeconds":1800,"hostsFileHealthy":true,"lockoutSecondsRemaining":30,"passwordSet":true,"pendingDelay":{"newDelaySeconds":600,"secondsRemaining":1700},"recoverySecondsRemaining":20,"uninstallSecondsRemaining":10,"version":"1.0.0"}}"#
        let decoded = try JSONCoding.decoder.decode(Response.self, from: Data(text.utf8))
        #expect(decoded == Response.success(status: Self.sampleStatus(), message: "reddit.com will unblock in 30 minutes."))
        #expect(decoded.ok && decoded.error == nil && decoded.errorCode == nil)
    }

    // Keys in any order, extra whitespace, and explicit nulls for the absent optional fields are all ordinary JSON a client may send or a log may hold.
    @Test func aResponseWithReorderedKeysWhitespaceAndExplicitNullsDecodes() throws {
        let text = #" { "status" : { "version":"1.0.0", "passwordSet":false, "blocked":[ ], "delaySeconds":1800, "hostsFileHealthy":true, "pendingDelay":null, "lockoutSecondsRemaining":null }, "message":null, "error":null, "errorCode":null, "ok":true } "#
        let idle = StatusSnapshot(version: "1.0.0", passwordSet: false, blocked: [], delaySeconds: 1800, pendingDelay: nil, uninstallSecondsRemaining: nil, recoverySecondsRemaining: nil, lockoutSecondsRemaining: nil, hostsFileHealthy: true)
        #expect(try JSONCoding.decoder.decode(Response.self, from: Data(text.utf8)) == Response.success(status: idle))
    }

    // 01-overview-and-data.md § StatusSnapshot: `adultFilterEnabled` is "decoded as `false` when missing, for an older daemon", so a newer client
    // reading a reply from an older daemon sees a filter that is not on, and an older client reading a newer reply ignores the extra key.
    @Test func aSnapshotWithoutAdultFilterEnabledDecodesItAsFalse() throws {
        let text = #"{"blocked":[],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":false,"version":"0.9.0"}"#
        let decoded = try JSONCoding.decoder.decode(StatusSnapshot.self, from: Data(text.utf8))
        #expect(decoded.adultFilterEnabled == false)
        #expect(decoded.delaySeconds == 1800 && decoded.version == "0.9.0")
    }

    // 01-overview-and-data.md § StatusSnapshot: `blockedPaths` is "decoded as empty when missing", so a client reading a reply from a daemon from before path rules sees no rules, and the reply still decodes.
    @Test func aSnapshotWithoutBlockedPathsDecodesItAsAnEmptyList() throws {
        let text = #"{"adultFilterEnabled":true,"blocked":[],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":false,"version":"1.0.0"}"#
        let decoded = try JSONCoding.decoder.decode(StatusSnapshot.self, from: Data(text.utf8))
        #expect(decoded.blockedPaths == [])
    }

    // A path rule status written by hand from the design's field names decodes into the matching values.
    @Test func aBlockedPathStatusWrittenByHandDecodes() throws {
        let text = #"{"adultFilterEnabled":true,"blocked":[],"blockedPaths":[{"domain":"youtube.com","path":"/shorts","rule":"youtube.com/shorts","unblockSecondsRemaining":60}],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":true,"version":"1.0.0"}"#
        let decoded = try JSONCoding.decoder.decode(StatusSnapshot.self, from: Data(text.utf8))
        #expect(decoded.blockedPaths == [BlockedPathStatus(domain: "youtube.com", path: "/shorts", rule: "youtube.com/shorts", unblockSecondsRemaining: 60)])
    }

    @Test func anExplicitAdultFilterEnabledTrueAndFalseDecodeAsWritten() throws {
        for value in [true, false] {
            let text = #"{"adultFilterEnabled":\#(value),"blocked":[],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":false,"version":"1.0.0"}"#
            #expect(try JSONCoding.decoder.decode(StatusSnapshot.self, from: Data(text.utf8)).adultFilterEnabled == value)
        }
    }

    // The engine is the daemon: every snapshot it builds says the filter is on, whatever else is going on.
    @Test func everySnapshotFromTheEngineReportsTheAdultFilterOn() throws {
        let fresh = makeEngine(password: nil)
        #expect(fresh.send(.status).status?.adultFilterEnabled == true)
        let busy = makeEngine(blocking: ["reddit.com"])
        busy.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(busy.send(.status).status?.adultFilterEnabled == true)
    }

    // A failure written by hand, using the two codes added in the current design.
    @Test(arguments: [("tooManySites", ErrorCode.tooManySites), ("notAllowed", ErrorCode.notAllowed), ("wrongPassword", ErrorCode.wrongPassword)])
    func aFailureResponseWrittenByHandDecodesToTheMatchingCode(wire: String, code: ErrorCode) throws {
        let text = #"{"error":"A sentence.","errorCode":"\#(wire)","ok":false}"#
        let decoded = try JSONCoding.decoder.decode(Response.self, from: Data(text.utf8))
        #expect(decoded == Response.failure(code, "A sentence."))
        #expect(try json(decoded) == text)
    }

    // Every one of the design's 16 code strings, typed out here, must decode and re-encode to the same string.
    @Test(arguments: ["badRequest", "invalidDomain", "notSetUp", "alreadySetUp", "wrongPassword", "lockedOut", "weakPassword", "notBlocked", "alreadyBlocked", "nothingPending", "invalidDelay", "notRoot", "notAllowed", "tooManySites", "invalidPath", "internal"])
    func everyErrorCodeStringFromTheDesignDecodesAndEncodesBackToItself(wire: String) throws {
        let text = #"{"errorCode":"\#(wire)","ok":false}"#
        let decoded = try JSONCoding.decoder.decode(Response.self, from: Data(text.utf8))
        #expect(decoded.errorCode?.rawValue == wire)
        #expect(try json(decoded) == text)
    }
}
