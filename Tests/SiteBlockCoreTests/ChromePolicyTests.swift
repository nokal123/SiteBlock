import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/03-daemon-cli-app.md § 9 ChromePolicyEnforcer ("Content rules"), not from the library:
//   urlBlocklist(for:) is "every host of every blocked site, lowercased, sorted, without duplicates. Sites with a pending unblock are included".
//   merged(existing:blocklist:) "keeps every other key already in the file and sets URLBlocklist to the list. With an empty list it removes
//   the URLBlocklist key, and when nothing else is left it returns nil, meaning the file is deleted."
// The key name is typed here as the literal Chrome policy name, not read from ChromePolicy.blocklistKey, so a changed constant is caught.

private let policyKey = "URLBlocklist"

// A blocked site with the given expanded hosts, as the engine would store it. A pending unblock is optional.
private func site(_ domain: String, _ hosts: [String], pending: Countdown? = nil) -> BlockedSite {
    BlockedSite(domain: domain, hosts: hosts, pendingUnblock: pending)
}

// True when both results are nil or both are equal property-list dictionaries. NSDictionary does the deep comparison of mixed value types.
private func same(_ left: [String: Any]?, _ right: [String: Any]?) -> Bool {
    switch (left, right) {
    case (nil, nil): return true
    case let (a?, b?): return NSDictionary(dictionary: a).isEqual(to: b)
    default: return false
    }
}

// The URLBlocklist value of a merged dictionary as strings, or nil when the key is missing or is not an array of strings.
private func listValue(_ dictionary: [String: Any]?) -> [String]? {
    dictionary?[policyKey] as? [String]
}

@Suite("ChromePolicy.urlBlocklist(for:)")
struct ChromePolicyBlocklistTests {
    // MARK: nothing to list

    @Test func anEmptySiteListGivesAnEmptyList() {
        #expect(ChromePolicy.urlBlocklist(for: []) == [])
    }

    // A site record with no hosts adds nothing, alone or next to a site that has hosts.
    @Test func aSiteWithNoHostsContributesNothing() {
        #expect(ChromePolicy.urlBlocklist(for: [site("a.com", [])]) == [])
        #expect(ChromePolicy.urlBlocklist(for: [site("a.com", []), site("b.com", ["b.com"])]) == ["b.com"])
    }

    // MARK: lowercase, sort, de-duplicate

    @Test func aSingleSiteGivesItsHostsSorted() {
        let listed = ChromePolicy.urlBlocklist(for: [site("example.com", ["www.example.com", "example.com", "m.example.com"])])
        #expect(listed == ["example.com", "m.example.com", "www.example.com"])
    }

    // Uppercase letters become lowercase. The sort runs on the lowercased names: "Zeta.com" would sort before "alpha.com" as typed, because capital letters come first in plain character order.
    @Test func hostsAreLowercased() {
        let listed = ChromePolicy.urlBlocklist(for: [site("zeta.com", ["Zeta.com", "WWW.Zeta.COM", "alpha.com"])])
        #expect(listed == ["alpha.com", "www.zeta.com", "zeta.com"])
    }

    // The same name in two sites, once in capitals, appears once. The de-duplication must happen after lowercasing, or "Example.com" and "example.com" would both stay.
    @Test func hostsAreSortedAndDeduplicatedAcrossSitesAfterLowercasing() {
        let first = site("zeta.com", ["Zeta.com", "shared.example.com", "alpha.com"])
        let second = site("beta.com", ["ALPHA.com", "beta.com", "SHARED.example.com", "beta.com"])
        let expected = ["alpha.com", "beta.com", "shared.example.com", "zeta.com"]
        #expect(ChromePolicy.urlBlocklist(for: [first, second]) == expected)
        #expect(ChromePolicy.urlBlocklist(for: [second, first]) == expected)
    }

    // A name repeated inside one site's own host list is listed once.
    @Test func aNameRepeatedInsideOneSiteIsListedOnce() {
        #expect(ChromePolicy.urlBlocklist(for: [site("a.com", ["a.com", "A.com", "a.com", "b.a.com"])]) == ["a.com", "b.a.com"])
    }

    // Sorting is plain character order, the same order DomainExpander and HostsFileEditor use ("sorted"): '-' comes before '.', and '.' comes before a digit.
    @Test func sortingIsPlainCharacterOrderForDashesDotsAndDigits() {
        let listed = ChromePolicy.urlBlocklist(for: [site("a.com", ["a1.com", "a.com", "a-b.com", "a.b.com", "a0.com", "b.com"])])
        #expect(listed == ["a-b.com", "a.b.com", "a.com", "a0.com", "a1.com", "b.com"])
    }

    // The answer is the same for every order of the same sites.
    @Test func theResultDoesNotDependOnTheOrderOfTheSites() {
        let sites = [
            site("c.com", ["c.com", "www.c.com", "Shared.net"]),
            site("a.com", ["a.com", "shared.net", "m.a.com"]),
            site("b.com", ["b.com", "www.b.com"]),
        ]
        let expected = ["a.com", "b.com", "c.com", "m.a.com", "shared.net", "www.b.com", "www.c.com"]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for order in orders {
            #expect(ChromePolicy.urlBlocklist(for: order.map { sites[$0] }) == expected, "site order \(order)")
        }
    }

    // MARK: pending unblocks stay listed

    // A site whose unblock countdown is running stays blocked until the countdown ends, so Chrome must keep refusing it.
    @Test func aSiteWithAPendingUnblockIsStillIncluded() {
        let pending = site("pending.com", ["pending.com", "www.pending.com"], pending: Countdown(seconds: 1800))
        let plain = site("plain.com", ["plain.com"])
        #expect(ChromePolicy.urlBlocklist(for: [pending, plain]) == ["pending.com", "plain.com", "www.pending.com"])
        #expect(ChromePolicy.urlBlocklist(for: [pending]) == ["pending.com", "www.pending.com"])
    }

    // The countdown being nearly over does not change that: only the engine removing the site (at zero) takes it off the list.
    @Test func aSiteWhoseUnblockCountdownIsAlmostOverIsStillIncluded() {
        var nearlyDone = Countdown(seconds: 1800)
        nearlyDone.advance(by: 1799.5)
        #expect(ChromePolicy.urlBlocklist(for: [site("last.com", ["last.com"], pending: nearlyDone)]) == ["last.com"])
    }
}

@Suite("ChromePolicy.merged(existing:blocklist:)")
struct ChromePolicyMergeTests {
    // MARK: a non-empty list

    // No file yet: the policy file holds only the block list.
    @Test func nilExistingWithAListGivesJustTheBlocklist() throws {
        let merged = ChromePolicy.merged(existing: nil, blocklist: ["a.com", "b.com"])
        #expect(same(merged, [policyKey: ["a.com", "b.com"]]))
        #expect(merged?.count == 1)
    }

    // An empty file (a property list with no keys) is the same as no file.
    @Test func anEmptyExistingDictionaryWithAListGivesJustTheBlocklist() {
        #expect(same(ChromePolicy.merged(existing: [:], blocklist: ["a.com"]), [policyKey: ["a.com"]]))
    }

    // A real company policy in the same file must survive, whatever the type of its value.
    @Test func otherExistingKeysAreKeptWithTheirValues() {
        let existing: [String: Any] = [
            "HomepageLocation": "https://intranet.example/",
            "ShowHomeButton": true,
            "RestoreOnStartup": 4,
            "RestoreOnStartupURLs": ["https://a.example/", "https://b.example/"],
            "ManagedBookmarks": [["name": "Wiki", "url": "https://wiki.example/"]],
            "ProxySettings": ["ProxyMode": "direct"],
        ]
        let merged = ChromePolicy.merged(existing: existing, blocklist: ["a.com"])
        var expected = existing
        expected[policyKey] = ["a.com"]
        #expect(same(merged, expected))
    }

    // SiteBlock's list replaces an older URLBlocklist; it is not appended to it, or an unblocked site would stay blocked forever.
    @Test func anExistingBlocklistIsReplacedNotExtended() {
        let merged = ChromePolicy.merged(existing: [policyKey: ["old.com", "a.com"], "HomepageLocation": "https://h.example/"], blocklist: ["a.com", "new.com"])
        #expect(listValue(merged) == ["a.com", "new.com"])
        #expect(merged?["HomepageLocation"] as? String == "https://h.example/")
        #expect(merged?.count == 2)
    }

    // The wrong-typed values a hand-edited file might hold under URLBlocklist.
    enum WrongType: CaseIterable, CustomTestStringConvertible {
        case string, number, boolean, dictionary, numbers

        var value: Any {
            switch self {
            case .string: return "block everything"
            case .number: return 7
            case .boolean: return true
            case .dictionary: return ["a.com": "x"]
            case .numbers: return [1, 2, 3]
            }
        }

        var testDescription: String { "\(self)" }
    }

    // A hand-edited file may hold a URLBlocklist of the wrong type. Chrome would ignore it, so it is overwritten with the list.
    @Test(arguments: WrongType.allCases)
    func anExistingNonArrayBlocklistIsReplaced(wrong: WrongType) {
        let merged = ChromePolicy.merged(existing: [policyKey: wrong.value, "Other": "kept"], blocklist: ["a.com"])
        #expect(listValue(merged) == ["a.com"], "URLBlocklist was \(wrong)")
        #expect(merged?["Other"] as? String == "kept", "URLBlocklist was \(wrong)")
        #expect(merged?.count == 2, "URLBlocklist was \(wrong)")
    }

    // MARK: an empty list

    // With nothing blocked the key goes, and the company's other keys stay.
    @Test func anEmptyListRemovesTheBlocklistAndKeepsOtherKeys() {
        let merged = ChromePolicy.merged(existing: [policyKey: ["a.com"], "HomepageLocation": "https://h.example/", "ShowHomeButton": true], blocklist: [])
        #expect(same(merged, ["HomepageLocation": "https://h.example/", "ShowHomeButton": true]))
        #expect(merged?[policyKey] == nil)
    }

    // The empty list must not leave an empty array behind either: Chrome would treat "URLBlocklist = []" as a company policy of "block nothing".
    @Test func anEmptyListDoesNotLeaveAnEmptyArrayBehind() {
        let merged = ChromePolicy.merged(existing: ["Other": 1], blocklist: [])
        #expect(merged != nil)
        #expect(merged?.keys.contains(policyKey) == false)
    }

    // Nothing left means the file should be deleted, which merged signals with nil.
    @Test func anEmptyListWithOnlyTheBlocklistPresentGivesNil() {
        #expect(ChromePolicy.merged(existing: [policyKey: ["a.com", "b.com"]], blocklist: []) == nil)
    }

    @Test func anEmptyListWithOnlyANonArrayBlocklistPresentGivesNil() {
        #expect(ChromePolicy.merged(existing: [policyKey: "not an array"], blocklist: []) == nil)
    }

    @Test func anEmptyListWithNoExistingFileGivesNil() {
        #expect(ChromePolicy.merged(existing: nil, blocklist: []) == nil)
    }

    @Test func anEmptyListWithAnEmptyExistingDictionaryGivesNil() {
        #expect(ChromePolicy.merged(existing: [:], blocklist: []) == nil)
    }

    // An empty list and no blocklist key in the file: the file is already right and keeps its keys.
    @Test func anEmptyListWithOtherKeysAndNoBlocklistLeavesThemAlone() {
        let existing: [String: Any] = ["HomepageLocation": "https://h.example/"]
        #expect(same(ChromePolicy.merged(existing: existing, blocklist: []), existing))
    }

    // MARK: idempotence

    // Running the merge on its own output changes nothing, so a pass that finds a correct file has nothing to write. Clearing then leaves exactly the other keys.
    @Test func mergingTheResultAgainGivesTheSameDictionary() {
        let list = ["a.com", "b.com"]
        let once = ChromePolicy.merged(existing: ["HomepageLocation": "https://h.example/"], blocklist: list)
        #expect(same(ChromePolicy.merged(existing: once, blocklist: list), once))
        #expect(same(ChromePolicy.merged(existing: once, blocklist: []), ["HomepageLocation": "https://h.example/"]))
    }
}
