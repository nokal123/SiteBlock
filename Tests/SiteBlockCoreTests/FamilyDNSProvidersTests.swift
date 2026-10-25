import Foundation
import Testing
import SiteBlockCore

// The family DNS providers file and its reader, and the reachability check's targets.
// Expected values come from Design Plans/02-core-components.md § 15 FamilyDNSProviders (the file's three parts, the three known providers and their addresses, the active
// provider, `servers` = IPv4 then IPv6, the `parse` rules, `isFamilyList`) and § 16 FamilyDNSProbe (`familyTargets` = the active provider's two IPv4 servers on UDP port 53),
// and 01-overview-and-data.md § Fixed Policy Values (the four adult-filter servers). Every address below is typed from the design text, never read from the file under test,
// so a wrong address in the file shows up as a failure here.

// The three known providers as the design lists them: (id, name, IPv4 pair, IPv6 pair).
private let designProviders: [(id: String, name: String, ipv4: [String], ipv6: [String])] = [
    ("cleanbrowsing-family", "CleanBrowsing Family Filter", ["185.228.168.168", "185.228.169.168"], ["2a0d:2a00:1::", "2a0d:2a00:2::"]),
    ("cloudflare-families", "Cloudflare for Families", ["1.1.1.3", "1.0.0.3"], ["2606:4700:4700::1113", "2606:4700:4700::1003"]),
    ("adguard-family", "AdGuard DNS Family Protection", ["94.140.14.15", "94.140.15.16"], ["2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff"]),
]

// The four adult-filter servers of 01 § Fixed Policy Values, in the order SiteBlock writes them.
private let cleanBrowsingServers = ["185.228.168.168", "185.228.169.168", "2a0d:2a00:1::", "2a0d:2a00:2::"]

// The providers file in the repository, read from disk next to this test file (Tests/SiteBlockCoreTests → Sources/SiteBlockCore).
private func repositoryProvidersFile(_ testFile: String = #filePath) throws -> Data {
    let root = URL(fileURLWithPath: testFile).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("Sources/SiteBlockCore/FamilyDNSProviders.json"))
}

// One provider entry as a JSON object, with the given addresses.
private func provider(_ id: String, ipv4: [String] = ["9.9.9.9", "149.112.112.112"], ipv6: [String] = ["2620:fe::fe", "2620:fe::9"]) -> [String: Any] {
    ["id": id, "name": "Provider \(id)", "ipv4": ipv4, "ipv6": ipv6]
}

// A whole providers file as JSON bytes: a readme, the active id and the providers.
private func file(active: String = "a", providers: [[String: Any]] = [provider("a")], extra: [String: Any] = [:]) throws -> Data {
    var object: [String: Any] = ["readme": "test file", "active": active, "providers": providers]
    for (key, value) in extra { object[key] = value }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

// One case of a file that breaks a rule of `parse`: a label for the report and the file.
struct BrokenProvidersFile: CustomTestStringConvertible, Sendable {
    let label: String
    let active: String
    let ipv4: [String]
    let ipv6: [String]
    let ids: [String]
    var testDescription: String { label }

    init(_ label: String, active: String = "a", ids: [String] = ["a"], ipv4: [String] = ["9.9.9.9", "149.112.112.112"], ipv6: [String] = ["2620:fe::fe", "2620:fe::9"]) {
        self.label = label
        self.active = active
        self.ids = ids
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    // The file: one provider per id, every provider with this case's addresses except that a second provider always has valid distinct ones.
    func data() throws -> Data {
        let entries = ids.enumerated().map { index, id in index == 0 ? provider(id, ipv4: ipv4, ipv6: ipv6) : provider(id, ipv4: ["1.1.1.3", "1.0.0.3"], ipv6: ["2606:4700:4700::1113", "2606:4700:4700::1003"]) }
        return try file(active: active, providers: entries)
    }
}

@Suite("FamilyDNSProviders: the built-in file")
struct FamilyDNSProvidersBuiltInTests {
    // 02 § 15: the built-in list is read with `parse`, so it is nil only when the file breaks a rule; the shipped file must not.
    @Test func theBuiltInFileParsesAndTheActiveProviderIsCleanBrowsingFamily() throws {
        let list = try #require(FamilyDNSProviders.builtIn, "the built-in providers file did not parse")
        #expect(list.active == "cleanbrowsing-family")
        #expect(list.activeProvider.id == "cleanbrowsing-family")
        #expect(list.activeProvider.name == "CleanBrowsing Family Filter")
        #expect(list.activeProvider.ipv4 == ["185.228.168.168", "185.228.169.168"])
        #expect(list.activeProvider.ipv6 == ["2a0d:2a00:1::", "2a0d:2a00:2::"])
        // `servers` is the IPv4 pair followed by the IPv6 pair, the order SiteBlock writes them (02 § 15 and 01 § Fixed Policy Values).
        #expect(list.activeProvider.servers == cleanBrowsingServers)
    }

    // 02 § 15 "The list is": exactly the three known providers, each with the design's name and addresses.
    @Test func theBuiltInFileHoldsExactlyTheThreeKnownProvidersWithTheDesignAddresses() throws {
        let list = try #require(FamilyDNSProviders.builtIn)
        #expect(Set(list.providers.map(\.id)) == Set(designProviders.map(\.id)))
        #expect(list.providers.count == 3)
        for expected in designProviders {
            let found = try #require(list.providers.first { $0.id == expected.id }, "\(expected.id) is missing")
            #expect(found.name == expected.name, "\(expected.id)")
            #expect(found.ipv4 == expected.ipv4, "\(expected.id)")
            #expect(found.ipv6 == expected.ipv6, "\(expected.id)")
            #expect(found.servers == expected.ipv4 + expected.ipv6, "\(expected.id)")
        }
    }

    // 02 § 15 "Where the file lives": the library holds the bytes of Sources/SiteBlockCore/FamilyDNSProviders.json. Parsing the file in the repository must give the same list
    // as the built-in copy, so a stale embed or a second copy of the file cannot go unnoticed.
    @Test func theBuiltInListIsTheListInTheRepositoryFile() throws {
        let fromDisk = try FamilyDNSProviders.parse(try repositoryProvidersFile())
        #expect(FamilyDNSProviders.builtIn == fromDisk)
        // The file's readme part is for people; it must be there in the shipped file.
        let object = try #require(try JSONSerialization.jsonObject(with: try repositoryProvidersFile()) as? [String: Any])
        #expect((object["readme"] as? String)?.isEmpty == false, "the file must carry its readme sentence")
    }

    // 02 § 16: the reachability check asks the active provider's two IPv4 servers, each on UDP port 53 (03 § 11 names them: 185.228.168.168 and 185.228.169.168).
    @Test func theReachabilityTargetsAreCleanBrowsingsTwoIPv4ServersOnPort53() {
        let targets = UDPFamilyDNSProbe.familyTargets.map { "\($0.host):\($0.port)" }
        #expect(targets == ["185.228.168.168:53", "185.228.169.168:53"])
    }
}

@Suite("FamilyDNSProviders.parse rules")
struct FamilyDNSProvidersParseTests {
    // Positive control for the rejection cases below: the same builder with nothing broken parses, so a rejection is caused by the one broken rule, not by the builder.
    @Test func aFileThatKeepsEveryRuleParsesWithItsValues() throws {
        let list = try FamilyDNSProviders.parse(try BrokenProvidersFile("valid", ids: ["a", "b"]).data())
        #expect(list.active == "a")
        #expect(list.providers.map(\.id) == ["a", "b"])
        #expect(list.activeProvider.servers == ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"])
        #expect(list.providers[0].name == "Provider a")
    }

    // 02 § 15 `parse`: every id is not empty and appears once; `active` names a provider; every provider has exactly 2 IPv4 and 2 IPv6 addresses, each valid and in its
    // standard short form (the form the system prints when it reads the address back). Each case breaks exactly one rule and must throw FamilyDNSProvidersError.
    static let brokenFiles: [BrokenProvidersFile] = [
        BrokenProvidersFile("empty id", active: "", ids: [""]),
        BrokenProvidersFile("empty id next to a valid active one", active: "b", ids: ["", "b"]),
        BrokenProvidersFile("repeated id", ids: ["a", "a"]),
        BrokenProvidersFile("active names no provider", active: "missing"),
        BrokenProvidersFile("active differs only in letter case", active: "A"),
        BrokenProvidersFile("no providers at all", active: "a", ids: []),
        BrokenProvidersFile("one IPv4 address", ipv4: ["9.9.9.9"]),
        BrokenProvidersFile("three IPv4 addresses", ipv4: ["9.9.9.9", "149.112.112.112", "9.9.9.10"]),
        BrokenProvidersFile("no IPv4 addresses", ipv4: []),
        BrokenProvidersFile("one IPv6 address", ipv6: ["2620:fe::fe"]),
        BrokenProvidersFile("three IPv6 addresses", ipv6: ["2620:fe::fe", "2620:fe::9", "2620:fe::10"]),
        BrokenProvidersFile("IPv4 octet over 255", ipv4: ["9.9.9.256", "149.112.112.112"]),
        BrokenProvidersFile("IPv4 that is not an address", ipv4: ["not-an-address", "149.112.112.112"]),
        BrokenProvidersFile("empty IPv4 text", ipv4: ["", "149.112.112.112"]),
        BrokenProvidersFile("IPv6 that is not an address", ipv6: ["2620:fe::zz", "2620:fe::9"]),
        BrokenProvidersFile("IPv4 address in the IPv6 list", ipv6: ["9.9.9.9", "2620:fe::9"]),
        BrokenProvidersFile("IPv6 address in the IPv4 list", ipv4: ["2620:fe::fe", "149.112.112.112"]),
        BrokenProvidersFile("IPv4 with a leading zero", ipv4: ["001.2.3.4", "149.112.112.112"]),
        BrokenProvidersFile("IPv4 with a zero-padded last part", ipv4: ["9.9.9.09", "149.112.112.112"]),
        BrokenProvidersFile("IPv4 with a space before it", ipv4: [" 9.9.9.9", "149.112.112.112"]),
        BrokenProvidersFile("IPv4 written as one number", ipv4: ["151587081", "149.112.112.112"]),
        BrokenProvidersFile("IPv4 with only three parts", ipv4: ["9.9.2313", "149.112.112.112"]),
        BrokenProvidersFile("uppercase IPv6", ipv6: ["2A0D:2A00:1::", "2620:fe::9"]),
        BrokenProvidersFile("IPv6 with a zero-padded group", ipv6: ["2a0d:2a00:0001::", "2620:fe::9"]),
        BrokenProvidersFile("IPv6 written out without ::", ipv6: ["2a0d:2a00:1:0:0:0:0:0", "2620:fe::9"]),
        BrokenProvidersFile("IPv6 with :: shortening a single zero group", ipv6: ["2a0d::1:2:3:4:5:6", "2620:fe::9"]),
        BrokenProvidersFile("IPv6 with :: on the shorter of two zero runs", ipv6: ["2a0d::1:0:0:0:1", "2620:fe::9"]),
        BrokenProvidersFile("IPv6 in square brackets", ipv6: ["[2620:fe::fe]", "2620:fe::9"]),
        // A zone index ("%5") is never part of what the system reads back from a DNS server setting, so it is not the standard form (and the Windows port must agree).
        BrokenProvidersFile("IPv6 with a zone index", ipv6: ["2620:fe::fe%5", "2620:fe::9"]),
    ]

    @Test(arguments: brokenFiles)
    func aFileThatBreaksOneRuleIsRejectedWithAProvidersError(_ broken: BrokenProvidersFile) throws {
        let data = try broken.data()
        #expect(throws: FamilyDNSProvidersError.self, "\(broken.label) was accepted") { try FamilyDNSProviders.parse(data) }
    }

    // The error carries one sentence naming the broken rule (02 § 15 FamilyDNSProvidersError), so it is never empty.
    @Test func theProvidersErrorCarriesASentence() throws {
        let data = try BrokenProvidersFile("repeated id", ids: ["a", "a"]).data()
        do {
            _ = try FamilyDNSProviders.parse(data)
            Issue.record("a repeated id was accepted")
        } catch let error as FamilyDNSProvidersError {
            #expect(!error.description.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // 02 § 15: `readme` is part of the file, and keys the reader does not use are ignored rather than rejected, at the top level and inside a provider.
    @Test func theReadmeAndOtherUnknownKeysAreAccepted() throws {
        var entry = provider("a")
        entry["homepage"] = "https://example.org"
        entry["notes"] = ["blocks adult sites"]
        let data = try file(providers: [entry], extra: ["readme": "people read this", "version": 2, "comment": ["x": 1]])
        let list = try FamilyDNSProviders.parse(data)
        #expect(list.activeProvider.servers == ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"])
        // Without a readme at all the file is still the expected JSON.
        let bare = try JSONSerialization.data(withJSONObject: ["active": "a", "providers": [provider("a")]])
        #expect(try FamilyDNSProviders.parse(bare).active == "a")
    }

    // 02 § 15: when the text is not the expected JSON, `parse` throws the JSON decoding error (not FamilyDNSProvidersError).
    static let malformed: [String] = [
        "",
        "not json",
        #"{"active": "a", "providers": [ {"id": "a""#,
        #"{"active": "a"}"#,
        #"{"providers": []}"#,
        #"{"active": "a", "providers": [{"id": "a", "name": "A", "ipv4": "9.9.9.9", "ipv6": ["2620:fe::fe", "2620:fe::9"]}]}"#,
        #"{"active": "a", "providers": [{"id": "a", "name": "A", "ipv4": [9, 9], "ipv6": ["2620:fe::fe", "2620:fe::9"]}]}"#,
        #"{"active": "a", "providers": [{"id": "a", "ipv4": ["9.9.9.9", "149.112.112.112"], "ipv6": ["2620:fe::fe", "2620:fe::9"]}]}"#,
        #"["active", "a"]"#,
        "42",
    ]

    @Test(arguments: malformed)
    func textThatIsNotTheExpectedJSONThrowsTheDecodingError(_ text: String) {
        #expect(throws: DecodingError.self, "accepted or wrong error for: \(text)") { try FamilyDNSProviders.parse(Data(text.utf8)) }
    }
}

@Suite("FamilyDNSProviders.isFamilyList")
struct FamilyDNSProvidersIsFamilyListTests {
    // 02 § 15: true when the servers equal one known provider's `servers` exactly, in order; any provider counts, not only the active one.
    @Test(arguments: designProviders.map { $0.ipv4 + $0.ipv6 })
    func everyKnownProvidersFourServersInOrderAreAFamilyList(_ servers: [String]) throws {
        let list = try #require(FamilyDNSProviders.builtIn)
        #expect(list.isFamilyList(servers))
    }

    // Anything that is not exactly one provider's four servers in order is not a family list.
    static let notFamilyLists: [[String]] = [
        ["185.228.169.168", "185.228.168.168", "2a0d:2a00:1::", "2a0d:2a00:2::"],
        ["2a0d:2a00:1::", "2a0d:2a00:2::", "185.228.168.168", "185.228.169.168"],
        ["185.228.168.168", "185.228.169.168"],
        ["2a0d:2a00:1::", "2a0d:2a00:2::"],
        ["185.228.168.168", "185.228.169.168", "2a0d:2a00:1::"],
        ["185.228.168.168", "185.228.169.168", "2a0d:2a00:1::", "2a0d:2a00:2::", "8.8.8.8"],
        ["185.228.168.168", "185.228.169.168", "2606:4700:4700::1113", "2606:4700:4700::1003"],
        ["185.228.168.168", "185.228.169.168", "2A0D:2A00:1::", "2A0D:2A00:2::"],
        ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
        ["192.168.1.1"],
        [],
    ]

    @Test(arguments: notFamilyLists)
    func aDifferentOrderASubsetAMixOrAnUnknownListIsNotAFamilyList(_ servers: [String]) throws {
        let list = try #require(FamilyDNSProviders.builtIn)
        #expect(!list.isFamilyList(servers), "\(servers)")
    }

    // The rule reads the providers of the list it is called on, so a parsed file's own provider counts and the built-in ones do not.
    @Test func aParsedFileRecognisesOnlyItsOwnProviders() throws {
        let list = try FamilyDNSProviders.parse(try file())
        #expect(list.isFamilyList(["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]))
        #expect(!list.isFamilyList(cleanBrowsingServers))
    }
}
