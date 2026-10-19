import Foundation
import Testing
import SiteBlockCore

// The wire form of a temporary unblock. Expected values come from Design Plans/01-overview-and-data.md § Wire Protocol (Request: `seconds` doubles as the window length
// and `startSeconds` is the start wait; the two new commands; the two new error codes; StatusSnapshot with `temporaryUnblock` on sites and path rules; TemporaryUnblockStatus:
// `opensInSeconds` nil once open, `secondsRemaining`, `windowSeconds`, `isOpen`) and 02-core-components.md § Models and Protocol Types ("JSON uses the default JSONEncoder with
// .sortedKeys, field names exactly as written in the design"; `BlockedSiteStatus` and `BlockedPathStatus` decode a missing `temporaryUnblock` as nil).

private func json(_ value: some Encodable) throws -> String { String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self) }
private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decoder.decode(type, from: Data(text.utf8)) }

private let waitingStatus = TemporaryUnblockStatus(opensInSeconds: 3600, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false)
private let openStatus = TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: 1500, windowSeconds: 1800, isOpen: true)

@Suite struct TemporaryUnblockProtocolTests {
    // MARK: request

    // 01 § Request: `startSeconds` is a new optional field, `seconds` is the window. Sorted keys, unused fields left out.
    @Test func aTemporaryUnblockRequestEncodesToOneLineOfSortedKeys() throws {
        let request = Request(command: .temporaryUnblock, domain: "reddit.com", password: "pw", seconds: 1800, startSeconds: 3600)
        #expect(try json(request) == #"{"command":"temporaryUnblock","domain":"reddit.com","password":"pw","seconds":1800,"startSeconds":3600}"#)
        let rule = Request(command: .temporaryUnblockPath, domain: "youtube.com/shorts", password: "pw", seconds: 900)
        #expect(try json(rule) == #"{"command":"temporaryUnblockPath","domain":"youtube.com\/shorts","password":"pw","seconds":900}"#, "a missing start wait is left out of the JSON")
    }

    @Test func aTemporaryUnblockRequestWrittenByHandFromTheDesignDecodes() throws {
        #expect(try decode(Request.self, #"{"command":"temporaryUnblock","domain":"reddit.com","password":"pw","seconds":1800,"startSeconds":3600}"#) == Request(command: .temporaryUnblock, domain: "reddit.com", password: "pw", seconds: 1800, startSeconds: 3600))
        #expect(try decode(Request.self, #"{"seconds":1800,"startSeconds":7200,"password":"p","domain":"youtube.com/shorts","command":"temporaryUnblockPath"}"#) == Request(command: .temporaryUnblockPath, domain: "youtube.com/shorts", password: "p", seconds: 1800, startSeconds: 7200))
    }

    // A request from a client that does not know the new field has no start wait; the explicit null means the same.
    @Test(arguments: [#"{"command":"temporaryUnblock","domain":"reddit.com","password":"pw","seconds":1800}"#, #"{"command":"temporaryUnblock","domain":"reddit.com","password":"pw","seconds":1800,"startSeconds":null}"#])
    func aRequestWithoutAStartWaitDecodesWithNil(text: String) throws {
        #expect(try decode(Request.self, text).startSeconds == nil)
    }

    // The daemon turns a decode failure into badRequest, so a start wait that is not a whole number must fail to decode and never become some number.
    @Test(arguments: [#"{"command":"temporaryUnblock","startSeconds":"30m"}"#, #"{"command":"temporaryUnblock","startSeconds":1.5}"#, #"{"command":"temporaryUnblock","startSeconds":true}"#, #"{"command":"temporaryUnblock","startSeconds":[1]}"#, #"{"command":"temporaryUnblock","startSeconds":99999999999999999999}"#])
    func aStartWaitThatIsNotAWholeNumberFailsToDecode(text: String) {
        #expect(throws: (any Error).self) { try decode(Request.self, text) }
    }

    // The two new command names, and every command still round-trips with a start wait.
    @Test func theNewCommandsHaveTheDesignsNamesOnTheWire() throws {
        #expect(Command.temporaryUnblock.rawValue == "temporaryUnblock" && Command.temporaryUnblockPath.rawValue == "temporaryUnblockPath")
        for command in Command.allCases {
            let request = Request(command: command, domain: "b\u{FC}cher.de/p", password: "p \"q\" \\", newPassword: "n", seconds: 14_400, startSeconds: 604_800)
            #expect(try decode(Request.self, try json(request)) == request)
        }
    }

    // The two new error codes decode from their wire strings and encode back to them.
    @Test(arguments: ["invalidDuration", "alreadyPending"])
    func theNewErrorCodesHaveTheDesignsNamesOnTheWire(wire: String) throws {
        let text = #"{"error":"A sentence.","errorCode":"\#(wire)","ok":false}"#
        let decoded = try decode(Response.self, text)
        #expect(decoded.errorCode?.rawValue == wire)
        #expect(try json(decoded) == text)
    }

    // MARK: status

    // 01 § TemporaryUnblockStatus: the four fields, with `opensInSeconds` left out once the site is open (default encoding drops a nil optional).
    @Test func theStatusEncodesWithTheDesignsFieldNames() throws {
        #expect(try json(waitingStatus) == #"{"isOpen":false,"opensInSeconds":3600,"secondsRemaining":1800,"windowSeconds":1800}"#)
        #expect(try json(openStatus) == #"{"isOpen":true,"secondsRemaining":1500,"windowSeconds":1800}"#)
    }

    @Test func aStatusWrittenByHandFromTheDesignDecodes() throws {
        #expect(try decode(TemporaryUnblockStatus.self, #"{"windowSeconds":1800,"secondsRemaining":1800,"opensInSeconds":3600,"isOpen":false}"#) == waitingStatus)
        #expect(try decode(TemporaryUnblockStatus.self, #"{"isOpen":true,"secondsRemaining":1500,"windowSeconds":1800}"#) == openStatus)
        #expect(try decode(TemporaryUnblockStatus.self, #"{"isOpen":true,"opensInSeconds":null,"secondsRemaining":1500,"windowSeconds":1800}"#) == openStatus)
    }

    // The three non-optional fields are required: a status without one is damaged, not a status from an older daemon (an older daemon has no status at all).
    @Test(arguments: ["secondsRemaining", "windowSeconds", "isOpen"])
    func aStatusMissingARequiredFieldFailsToDecode(missing: String) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(#"{"isOpen":false,"opensInSeconds":3600,"secondsRemaining":1800,"windowSeconds":1800}"#.utf8)) as? [String: Any])
        object.removeValue(forKey: missing)
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONCoding.decoder.decode(TemporaryUnblockStatus.self, from: data) }
    }

    // A full reply with a temporary unblock on a site and on a rule, written out by hand from the design's field names in sorted order (Foundation escapes "/" as "\/").
    @Test func aReplyWithTemporaryUnblocksEncodesToExactlyTheDesignsJSON() throws {
        let status = StatusSnapshot(version: "1.0.0", passwordSet: true, blocked: [BlockedSiteStatus(domain: "reddit.com", hosts: ["reddit.com"], unblockSecondsRemaining: nil, temporaryUnblock: waitingStatus), BlockedSiteStatus(domain: "example.com", hosts: ["example.com"], unblockSecondsRemaining: nil)], delaySeconds: 1800, pendingDelay: nil, uninstallSecondsRemaining: nil, recoverySecondsRemaining: nil, lockoutSecondsRemaining: nil, hostsFileHealthy: true, adultFilterEnabled: true, blockedPaths: [BlockedPathStatus(domain: "youtube.com", path: "/shorts", rule: "youtube.com/shorts", unblockSecondsRemaining: nil, temporaryUnblock: openStatus)])
        let expected = #"{"ok":true,"status":{"adultFilterEnabled":true,"blocked":[{"domain":"reddit.com","hosts":["reddit.com"],"temporaryUnblock":{"isOpen":false,"opensInSeconds":3600,"secondsRemaining":1800,"windowSeconds":1800}},{"domain":"example.com","hosts":["example.com"]}],"blockedPaths":[{"domain":"youtube.com","path":"\/shorts","rule":"youtube.com\/shorts","temporaryUnblock":{"isOpen":true,"secondsRemaining":1500,"windowSeconds":1800}}],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":true,"version":"1.0.0"}}"#
        #expect(try json(Response.success(status: status)) == expected)
        #expect(try decode(Response.self, expected) == Response.success(status: status))
    }

    // 01 § StatusSnapshot / TemporaryUnblockStatus: the key "decode[s] as nil when the key is missing, for an older daemon", on sites and on path rules, and everything else in the reply still decodes.
    @Test func aStatusReplyFromAnOlderDaemonWithoutTheKeyDecodesWithNil() throws {
        let text = #"{"adultFilterEnabled":true,"blocked":[{"domain":"reddit.com","hosts":["reddit.com","www.reddit.com"],"unblockSecondsRemaining":600}],"blockedPaths":[{"domain":"youtube.com","path":"/shorts","rule":"youtube.com/shorts","unblockSecondsRemaining":60}],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":true,"version":"0.9.0"}"#
        let decoded = try decode(StatusSnapshot.self, text)
        #expect(decoded.blocked == [BlockedSiteStatus(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"], unblockSecondsRemaining: 600, temporaryUnblock: nil)])
        #expect(decoded.blocked.first?.temporaryUnblock == nil)
        #expect(decoded.blockedPaths == [BlockedPathStatus(domain: "youtube.com", path: "/shorts", rule: "youtube.com/shorts", unblockSecondsRemaining: 60, temporaryUnblock: nil)])
        #expect(decoded.blockedPaths?.first?.temporaryUnblock == nil)
        #expect(decoded.delaySeconds == 1800 && decoded.version == "0.9.0")
    }

    // The oldest shape, from before path rules existed: no blockedPaths and no temporaryUnblock anywhere.
    @Test func aStatusReplyFromTheOldestDaemonDecodes() throws {
        let text = #"{"blocked":[{"domain":"reddit.com","hosts":["reddit.com"]}],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":true,"version":"0.5.0"}"#
        let decoded = try decode(StatusSnapshot.self, text)
        #expect(decoded.blocked.first?.temporaryUnblock == nil && decoded.blockedPaths == [])
    }

    // A reply from a newer daemon with a status inside a site decodes on the entry it belongs to, in each of the two phases.
    @Test func aStatusInsideASiteAndInsideARuleDecodesOnThatEntry() throws {
        let text = #"{"blocked":[{"domain":"a.example","hosts":["a.example"],"temporaryUnblock":{"isOpen":false,"opensInSeconds":60,"secondsRemaining":300,"windowSeconds":300}},{"domain":"b.example","hosts":["b.example"]}],"blockedPaths":[{"domain":"c.example","path":"/x","rule":"c.example/x","temporaryUnblock":{"isOpen":true,"secondsRemaining":299,"windowSeconds":300}}],"delaySeconds":60,"hostsFileHealthy":true,"passwordSet":true,"version":"1.0.0"}"#
        let decoded = try decode(StatusSnapshot.self, text)
        #expect(decoded.blocked.map(\.temporaryUnblock) == [TemporaryUnblockStatus(opensInSeconds: 60, secondsRemaining: 300, windowSeconds: 300, isOpen: false), nil])
        #expect(decoded.blockedPaths?.first?.temporaryUnblock == TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: 299, windowSeconds: 300, isOpen: true))
    }

    // A real reply from the engine, with a waiting and an open temporary unblock, survives the wire as one line.
    @Test func aReplyFromTheEngineWithTemporaryUnblocksRoundTripsThroughTheWire() throws {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 3600))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 900, start: 1800, rule: true))
        _ = engine.tick(elapsed: 1800)
        for response in [engine.send(.status), engine.send(.cancelUnblock, domain: "reddit.com"), engine.temporarily("example.com", seconds: 1800, start: 7200), engine.temporarily("example.com", seconds: 1, start: 7200)] {
            let data = try JSONCoding.encoder.encode(response)
            #expect(!data.contains(0x0A), "a reply must be a single line")
            #expect(try JSONCoding.decoder.decode(Response.self, from: data) == response)
        }
        let status = engine.send(.status).status
        #expect(status?.blockedPaths?.first?.temporaryUnblock?.isOpen == true)
    }
}
