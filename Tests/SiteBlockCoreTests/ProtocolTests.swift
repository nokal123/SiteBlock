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
    @Test func theCommandNamesOnTheWireAreExactlyTheDesignsTwelve() {
        let expected: Set<String> = ["status", "setup", "add", "unblock", "cancelUnblock", "setDelay", "cancelDelayChange", "changePassword", "uninstall", "cancelUninstall", "recoveryStart", "recoveryCancel"]
        #expect(Set(Command.allCases.map(\.rawValue)) == expected)
        #expect(Command.allCases.count == 12)
    }

    @Test func theErrorCodesOnTheWireAreExactlyTheDesignsThirteen() {
        let expected: Set<String> = ["badRequest", "invalidDomain", "notSetUp", "alreadySetUp", "wrongPassword", "lockedOut", "weakPassword", "notBlocked", "alreadyBlocked", "nothingPending", "invalidDelay", "notRoot", "internal"]
        #expect(Set(ErrorCode.allCases.map(\.rawValue)) == expected)
        #expect(ErrorCode.allCases.count == 13)
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

    private static func sampleStatus() -> StatusSnapshot {
        StatusSnapshot(version: "1.0.0", passwordSet: true, blocked: [BlockedSiteStatus(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"], unblockSecondsRemaining: 1800), BlockedSiteStatus(domain: "example.com", hosts: ["example.com"], unblockSecondsRemaining: nil)], delaySeconds: 1800, pendingDelay: PendingDelayStatus(newDelaySeconds: 600, secondsRemaining: 1700), uninstallSecondsRemaining: 10, recoverySecondsRemaining: 20, lockoutSecondsRemaining: 30, hostsFileHealthy: true)
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
        #expect(Set(object.keys) == ["version", "passwordSet", "blocked", "delaySeconds", "pendingDelay", "uninstallSecondsRemaining", "recoverySecondsRemaining", "lockoutSecondsRemaining", "hostsFileHealthy"])
        let sites = try #require(object["blocked"] as? [[String: Any]])
        let site = try #require(sites.first)
        #expect(Set(site.keys) == ["domain", "hosts", "unblockSecondsRemaining"])
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
}
