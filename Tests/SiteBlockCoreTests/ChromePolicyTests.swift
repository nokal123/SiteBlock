import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/03-daemon-cli-app.md § 9 ChromePolicyEnforcer ("Content rules"), not from the library:
//   urlBlocklist(for:) is "the shortest list that covers every host of every blocked site: hosts lowercased, duplicates removed, and any
//   host left out when a parent domain of it (whole labels only) is also in the list, because a Chrome URLBlocklist entry such as
//   youtube.com already blocks every subdomain. Sorted. ... Sites with a pending unblock are included."
//   merged(existing:blocklist:) "keeps every other key already in the file and sets URLBlocklist to the list. With an empty list it removes
//   the URLBlocklist key, and when nothing else is left it returns nil, meaning the file is deleted."
// The expectations of the urlBlocklist tests changed with the design change in 03 § 9 (the list used to hold every host, now it holds only
// hosts that no other listed host covers). The key name is typed here as the literal Chrome policy name, not read from
// ChromePolicy.blocklistKey, so a changed constant is caught.

private let policyKey = "URLBlocklist"

// Design change: 03-daemon-cli-app.md § 9 ChromePolicyEnforcer ("Content rules") replaced `merged(existing:blocklist:)` with
// `merged(existing:managed:)`, where `managed` comes from `managedValues(blocklist:adultFilter:)` and also carries the three adult-filter
// keys. The tests below were written for the old signature and only exercise the URLBlocklist key, so this helper builds the `managed`
// dictionary the way the enforcer does with the adult filter off (adultFilter: false adds no adult-filter keys). Their expected values are unchanged.
private func mergedBlocklist(existing: [String: Any]?, blocklist: [String]) -> [String: Any]? {
    ChromePolicy.merged(existing: existing, managed: ChromePolicy.managedValues(blocklist: blocklist, adultFilter: false))
}

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

// The design's covering rule written a second way, so it does not share code with the library: lowercase every host, remove duplicates, drop
// any host that ends in "." followed by another host of the set (a parent domain, whole labels only), and sort. A pairwise suffix test is used
// here where the library walks the labels.
private func shortestCover(_ hosts: [String]) -> [String] {
    let all = Set(hosts.map { $0.lowercased() })
    return all.filter { host in !all.contains(where: { $0 != host && host.hasSuffix("." + $0) }) }.sorted()
}

// The 26 hosts that "youtube.com" expands to, typed from 02-core-components.md § DomainExpander: the base, the eight common prefixes, the eleven
// related names, and www. and m. in front of the three related names that have two labels.
private let youtubeExpansion = [
    "youtube.com", "www.youtube.com", "m.youtube.com", "mobile.youtube.com", "old.youtube.com", "new.youtube.com", "amp.youtube.com", "app.youtube.com", "web.youtube.com",
    "music.youtube.com", "tv.youtube.com", "studio.youtube.com",
    "youtu.be", "www.youtu.be", "m.youtu.be",
    "youtube-nocookie.com", "www.youtube-nocookie.com", "m.youtube-nocookie.com",
    "youtubekids.com", "www.youtubekids.com", "m.youtubekids.com",
    "youtubei.googleapis.com", "youtube.googleapis.com", "i.ytimg.com", "s.ytimg.com", "yt3.ggpht.com",
]

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

    @Test func hostsOfOneSiteThatCoverNothingAreGivenSorted() {
        let listed = ChromePolicy.urlBlocklist(for: [site("zeta.com", ["zeta.com", "mid.net", "alpha.com"])])
        #expect(listed == ["alpha.com", "mid.net", "zeta.com"])
    }

    // Uppercase letters become lowercase. The sort runs on the lowercased names: "Zeta.com" would sort before "alpha.net" as typed, because capital letters come first in plain character order.
    @Test func hostsAreLowercased() {
        let listed = ChromePolicy.urlBlocklist(for: [site("zeta.com", ["Zeta.com", "ALPHA.net", "Beta.org"])])
        #expect(listed == ["alpha.net", "beta.org", "zeta.com"])
    }

    // The same name in two sites, once in capitals, appears once. The de-duplication must happen after lowercasing, or "Alpha.com" and "alpha.com" would both stay.
    @Test func hostsAreSortedAndDeduplicatedAcrossSitesAfterLowercasing() {
        let first = site("zeta.com", ["Zeta.com", "shared.example.net", "alpha.com"])
        let second = site("beta.com", ["ALPHA.com", "beta.com", "SHARED.example.net", "beta.com"])
        let expected = ["alpha.com", "beta.com", "shared.example.net", "zeta.com"]
        #expect(ChromePolicy.urlBlocklist(for: [first, second]) == expected)
        #expect(ChromePolicy.urlBlocklist(for: [second, first]) == expected)
    }

    // A name repeated inside one site's own host list is listed once.
    @Test func aNameRepeatedInsideOneSiteIsListedOnce() {
        #expect(ChromePolicy.urlBlocklist(for: [site("a.com", ["a.com", "A.com", "a.com", "b.com"])]) == ["a.com", "b.com"])
    }

    // Sorting is plain character order, the same order DomainExpander and HostsFileEditor use ("sorted"): '-' comes before '.', and '.' comes before a digit. None of these names is covered by another.
    @Test func sortingIsPlainCharacterOrderForDashesDotsAndDigits() {
        let listed = ChromePolicy.urlBlocklist(for: [site("a.com", ["a1.com", "a.com", "a-b.com", "a.b.net", "a0.com", "b.com"])])
        #expect(listed == ["a-b.com", "a.b.net", "a.com", "a0.com", "a1.com", "b.com"])
    }

    // The answer is the same for every order of the same sites.
    @Test func theResultDoesNotDependOnTheOrderOfTheSites() {
        let sites = [
            site("c.com", ["c.com", "www.c.com", "Shared.net"]),
            site("a.com", ["a.com", "shared.net", "m.a.com"]),
            site("b.com", ["b.com", "www.b.com"]),
        ]
        let expected = ["a.com", "b.com", "c.com", "shared.net"]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for order in orders {
            #expect(ChromePolicy.urlBlocklist(for: order.map { sites[$0] }) == expected, "site order \(order)")
        }
    }

    // MARK: parent domains cover their subdomains (03 § 9: the shortest covering list)

    // A subdomain is left out when its parent is listed, because the parent entry already blocks it.
    @Test func aHostWhoseParentIsListedIsLeftOut() {
        #expect(ChromePolicy.urlBlocklist(for: [site("example.com", ["example.com", "www.example.com", "m.example.com"])]) == ["example.com"])
    }

    // Only whole labels count: "notyoutube.com" ends in the letters "youtube.com" but is a different domain, so Chrome would not block it through the "youtube.com" entry. The same goes for a name that merely contains the parent, or a name where the parent is the front part.
    @Test(arguments: ["notyoutube.com", "xyoutube.com", "my-youtube.com", "youtube.com.evil.com", "youtube.com.au", "youtubee.com"])
    func aHostThatOnlyEndsInTheLettersOfAnotherHostIsNotCovered(lookalike: String) {
        let listed = ChromePolicy.urlBlocklist(for: [site("youtube.com", ["youtube.com", lookalike])])
        #expect(listed == [lookalike, "youtube.com"].sorted(), "\(lookalike) must stay in the list next to youtube.com")
    }

    // The parent does not have to be the next label up: "a.b.c.com" is covered by "c.com" although "b.c.com" is not listed.
    @Test func aHostIsCoveredByAParentSeveralLabelsUp() {
        #expect(ChromePolicy.urlBlocklist(for: [site("c.com", ["a.b.c.com", "c.com"])]) == ["c.com"])
        #expect(ChromePolicy.urlBlocklist(for: [site("c.com", ["a.b.c.com", "x.y.z.c.com", "c.com"])]) == ["c.com"])
    }

    // With a whole chain present, only the top of it stays.
    @Test func inAChainOfParentsOnlyTheTopOneStays() {
        #expect(ChromePolicy.urlBlocklist(for: [site("z.com", ["x.y.z.com", "y.z.com", "z.com"])]) == ["z.com"])
    }

    // A parent that is itself covered does not stay, and a middle parent covers what is below it when the top is absent.
    @Test func theNearestListedParentCoversWhenTheTopIsAbsent() {
        #expect(ChromePolicy.urlBlocklist(for: [site("c.com", ["a.b.c.com", "b.c.com"])]) == ["b.c.com"])
    }

    // Names with the same parent but not each other stay side by side.
    @Test func siblingsAreNotCoveredByEachOther() {
        #expect(ChromePolicy.urlBlocklist(for: [site("c.com", ["a.c.com", "b.c.com"])]) == ["a.c.com", "b.c.com"])
    }

    // A child never covers its parent.
    @Test func aChildDoesNotCoverItsParent() {
        #expect(ChromePolicy.urlBlocklist(for: [site("c.com", ["www.c.com"])]) == ["www.c.com"])
    }

    // The host and its parent come from two different sites: the covering is decided across all sites, not inside each site.
    @Test func aHostAndItsParentFromTwoDifferentSitesLeaveOnlyTheParent() {
        let parent = site("example.com", ["example.com"])
        let child = site("shop.example.com", ["shop.example.com", "www.shop.example.com"])
        #expect(ChromePolicy.urlBlocklist(for: [parent, child]) == ["example.com"])
        #expect(ChromePolicy.urlBlocklist(for: [child, parent]) == ["example.com"])
    }

    // Capital letters do not hide a parent: "EXAMPLE.com" covers "www.Example.COM".
    @Test func coveringIgnoresLetterCase() {
        #expect(ChromePolicy.urlBlocklist(for: [site("a", ["www.Example.COM"]), site("b", ["EXAMPLE.com"])]) == ["example.com"])
        #expect(ChromePolicy.urlBlocklist(for: [site("a", ["EXAMPLE.com", "www.Example.COM", "Mail.example.com"])]) == ["example.com"])
    }

    // The design's example: the 26 hosts youtube.com expands to give exactly these nine entries.
    @Test func theYoutubeExpansionGivesTheDesignsNineEntries() {
        #expect(youtubeExpansion.count == 26)
        let expected = ["i.ytimg.com", "s.ytimg.com", "youtu.be", "youtube-nocookie.com", "youtube.com", "youtube.googleapis.com", "youtubei.googleapis.com", "youtubekids.com", "yt3.ggpht.com"]
        #expect(ChromePolicy.urlBlocklist(for: [site("youtube.com", youtubeExpansion)]) == expected)
        // The same names split over two sites, in either order, give the same list.
        let split = [site("a", Array(youtubeExpansion[0..<10])), site("b", Array(youtubeExpansion[10...]))]
        #expect(ChromePolicy.urlBlocklist(for: split) == expected)
        #expect(ChromePolicy.urlBlocklist(for: split.reversed()) == expected)
    }

    // 03 § 9: "even 500 blocked sites" stay well below Chrome's limit of 1,000 entries. Each site here has nine hosts (the base and the eight common prefixes), as an ordinary site expands; each is covered by its base, so 500 entries remain. All 4,500 names are distinct, so only the covering makes the difference.
    @Test func fiveHundredSitesOfNineHostsEachStayUnderChromesLimit() {
        let prefixes = ["www", "m", "mobile", "old", "new", "amp", "app", "web"]
        let sites = (0..<500).map { index -> BlockedSite in
            let base = "site\(index).example"
            return site(base, [base] + prefixes.map { "\($0).\(base)" })
        }
        let hostCount = sites.reduce(0) { $0 + $1.hosts.count }
        #expect(hostCount == 4500)
        let listed = ChromePolicy.urlBlocklist(for: sites)
        #expect(listed.count <= 1000)
        #expect(listed == (0..<500).map { "site\($0).example" }.sorted())
    }

    // MARK: pending unblocks stay listed

    // A site whose unblock countdown is running stays blocked until the countdown ends, so Chrome must keep refusing it.
    @Test func aSiteWithAPendingUnblockIsStillIncluded() {
        let pending = site("pending.com", ["pending.com", "www.pending.com"], pending: Countdown(seconds: 1800))
        let plain = site("plain.com", ["plain.com"])
        #expect(ChromePolicy.urlBlocklist(for: [pending, plain]) == ["pending.com", "plain.com"])
        #expect(ChromePolicy.urlBlocklist(for: [pending]) == ["pending.com"])
    }

    // The pending site's names also take part in the covering: its parent name covers another site's subdomain, and its subdomain stays listed when the parent belongs to a plain site.
    @Test func aPendingSiteCoversAndIsCoveredLikeAnyOther() {
        let pending = site("example.com", ["example.com"], pending: Countdown(seconds: 1800))
        let plain = site("shop.example.com", ["shop.example.com"])
        #expect(ChromePolicy.urlBlocklist(for: [pending, plain]) == ["example.com"])
        let pendingChild = site("shop.example.com", ["shop.example.com"], pending: Countdown(seconds: 1800))
        #expect(ChromePolicy.urlBlocklist(for: [pendingChild]) == ["shop.example.com"])
    }

    // The countdown being nearly over does not change that: only the engine removing the site (at zero) takes it off the list.
    @Test func aSiteWhoseUnblockCountdownIsAlmostOverIsStillIncluded() {
        var nearlyDone = Countdown(seconds: 1800)
        nearlyDone.advance(by: 1799.5)
        #expect(ChromePolicy.urlBlocklist(for: [site("last.com", ["last.com"], pending: nearlyDone)]) == ["last.com"])
    }

    // MARK: cross-check against the second formulation of the rule

    // A small seeded generator makes sites out of a few short labels in mixed case, so parents, children, look-alikes and duplicates all occur often. The library must agree with the pairwise reference on every case. The counters guard against a generator that stops producing the interesting cases.
    @Test func theLibraryAgreesWithTheIndependentReferenceOnGeneratedSites() {
        var state: UInt64 = 0x5EED_C0DE_2026
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let labels = ["a", "b", "ab", "c", "A", "B"]
        let tails = ["com", "net", "Com", "co.uk"]
        var covered = 0, shared = 0, nonTrivial = 0
        for _ in 0..<400 {
            let sites = (0..<(1 + next(4))).map { index -> BlockedSite in
                let hosts = (0..<next(7)).map { _ in ((0..<(1 + next(3))).map { _ in labels[next(labels.count)] } + [tails[next(tails.count)]]).joined(separator: ".") }
                return site("s\(index)", hosts)
            }
            let allHosts = sites.flatMap(\.hosts)
            let expected = shortestCover(allHosts)
            #expect(ChromePolicy.urlBlocklist(for: sites) == expected, "sites: \(sites.map(\.hosts))")
            if expected.count < Set(allHosts.map { $0.lowercased() }).count { covered += 1 }
            if sites.count > 1 && expected.count > 1 { shared += 1 }
            if expected.count >= 3 { nonTrivial += 1 }
        }
        #expect(covered > 100, "only \(covered) generated cases had a covered host")
        #expect(shared > 100)
        #expect(nonTrivial > 100)
    }

    // The reference itself gives the design's example, so the cross-check above is not comparing against a wrong rule.
    @Test func theReferenceGivesTheDesignsYoutubeExample() {
        #expect(shortestCover(youtubeExpansion) == ["i.ytimg.com", "s.ytimg.com", "youtu.be", "youtube-nocookie.com", "youtube.com", "youtube.googleapis.com", "youtubei.googleapis.com", "youtubekids.com", "yt3.ggpht.com"])
        #expect(shortestCover(["notyoutube.com", "youtube.com"]) == ["notyoutube.com", "youtube.com"])
    }
}

@Suite("mergedBlocklist(existing:blocklist:)")
struct ChromePolicyMergeTests {
    // MARK: a non-empty list

    // No file yet: the policy file holds only the block list.
    @Test func nilExistingWithAListGivesJustTheBlocklist() throws {
        let merged = mergedBlocklist(existing: nil, blocklist: ["a.com", "b.com"])
        #expect(same(merged, [policyKey: ["a.com", "b.com"]]))
        #expect(merged?.count == 1)
    }

    // An empty file (a property list with no keys) is the same as no file.
    @Test func anEmptyExistingDictionaryWithAListGivesJustTheBlocklist() {
        #expect(same(mergedBlocklist(existing: [:], blocklist: ["a.com"]), [policyKey: ["a.com"]]))
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
        let merged = mergedBlocklist(existing: existing, blocklist: ["a.com"])
        var expected = existing
        expected[policyKey] = ["a.com"]
        #expect(same(merged, expected))
    }

    // SiteBlock's list replaces an older URLBlocklist; it is not appended to it, or an unblocked site would stay blocked forever.
    @Test func anExistingBlocklistIsReplacedNotExtended() {
        let merged = mergedBlocklist(existing: [policyKey: ["old.com", "a.com"], "HomepageLocation": "https://h.example/"], blocklist: ["a.com", "new.com"])
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
        let merged = mergedBlocklist(existing: [policyKey: wrong.value, "Other": "kept"], blocklist: ["a.com"])
        #expect(listValue(merged) == ["a.com"], "URLBlocklist was \(wrong)")
        #expect(merged?["Other"] as? String == "kept", "URLBlocklist was \(wrong)")
        #expect(merged?.count == 2, "URLBlocklist was \(wrong)")
    }

    // MARK: an empty list

    // With nothing blocked the key goes, and the company's other keys stay.
    @Test func anEmptyListRemovesTheBlocklistAndKeepsOtherKeys() {
        let merged = mergedBlocklist(existing: [policyKey: ["a.com"], "HomepageLocation": "https://h.example/", "ShowHomeButton": true], blocklist: [])
        #expect(same(merged, ["HomepageLocation": "https://h.example/", "ShowHomeButton": true]))
        #expect(merged?[policyKey] == nil)
    }

    // The empty list must not leave an empty array behind either: Chrome would treat "URLBlocklist = []" as a company policy of "block nothing".
    @Test func anEmptyListDoesNotLeaveAnEmptyArrayBehind() {
        let merged = mergedBlocklist(existing: ["Other": 1], blocklist: [])
        #expect(merged != nil)
        #expect(merged?.keys.contains(policyKey) == false)
    }

    // Nothing left means the file should be deleted, which merged signals with nil.
    @Test func anEmptyListWithOnlyTheBlocklistPresentGivesNil() {
        #expect(mergedBlocklist(existing: [policyKey: ["a.com", "b.com"]], blocklist: []) == nil)
    }

    @Test func anEmptyListWithOnlyANonArrayBlocklistPresentGivesNil() {
        #expect(mergedBlocklist(existing: [policyKey: "not an array"], blocklist: []) == nil)
    }

    @Test func anEmptyListWithNoExistingFileGivesNil() {
        #expect(mergedBlocklist(existing: nil, blocklist: []) == nil)
    }

    @Test func anEmptyListWithAnEmptyExistingDictionaryGivesNil() {
        #expect(mergedBlocklist(existing: [:], blocklist: []) == nil)
    }

    // An empty list and no blocklist key in the file: the file is already right and keeps its keys.
    @Test func anEmptyListWithOtherKeysAndNoBlocklistLeavesThemAlone() {
        let existing: [String: Any] = ["HomepageLocation": "https://h.example/"]
        #expect(same(mergedBlocklist(existing: existing, blocklist: []), existing))
    }

    // MARK: idempotence

    // Running the merge on its own output changes nothing, so a pass that finds a correct file has nothing to write. Clearing then leaves exactly the other keys.
    @Test func mergingTheResultAgainGivesTheSameDictionary() {
        let list = ["a.com", "b.com"]
        let once = mergedBlocklist(existing: ["HomepageLocation": "https://h.example/"], blocklist: list)
        #expect(same(mergedBlocklist(existing: once, blocklist: list), once))
        #expect(same(mergedBlocklist(existing: once, blocklist: []), ["HomepageLocation": "https://h.example/"]))
    }
}

// 03-daemon-cli-app.md § 9 ChromePolicyEnforcer, "Adult-filter keys" and "Content rules": while the adult content filter is on, the policy file
// carries SafeSitesFilterBehavior = 1 (integer), ForceGoogleSafeSearch = true (boolean) and DnsOverHttpsMode = "off" (string), and URLBlocklist
// only when the list is not empty. The key names and the value types are typed here from the design. Chrome ignores a policy whose type is wrong,
// so the types are checked through a property list round trip, the way the file is written.
@Suite("ChromePolicy adult filter keys")
struct ChromePolicyAdultFilterTests {
    private let filterKeys = ["SafeSitesFilterBehavior", "ForceGoogleSafeSearch", "DnsOverHttpsMode"]

    // Writes the dictionary as an XML property list and returns the text, so the types show as elements (<integer>, <true/>, <string>).
    private func xml(_ dictionary: [String: Any]) throws -> String {
        String(decoding: try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0), as: UTF8.self)
    }

    @Test func managedKeysAreExactlyTheFourDesignKeys() {
        #expect(Set(ChromePolicy.managedKeys) == ["URLBlocklist", "SafeSitesFilterBehavior", "ForceGoogleSafeSearch", "DnsOverHttpsMode"])
    }

    @Test func withTheFilterOnAndNoSitesTheManagedValuesAreTheThreeFilterKeysWithTheRightTypes() throws {
        let values = ChromePolicy.managedValues(blocklist: [], adultFilter: true)
        #expect(Set(values.keys) == Set(filterKeys))
        let text = try xml(values)
        #expect(text.contains("<key>SafeSitesFilterBehavior</key>\n\t<integer>1</integer>"))
        #expect(text.contains("<key>ForceGoogleSafeSearch</key>\n\t<true/>"))
        #expect(text.contains("<key>DnsOverHttpsMode</key>\n\t<string>off</string>"))
    }

    @Test func withTheFilterOnAndSitesTheListIsAddedToTheThreeFilterKeys() {
        let values = ChromePolicy.managedValues(blocklist: ["a.com", "b.com"], adultFilter: true)
        #expect(Set(values.keys) == Set(filterKeys + ["URLBlocklist"]))
        #expect(values["URLBlocklist"] as? [String] == ["a.com", "b.com"])
    }

    @Test func withTheFilterOffTheFilterKeysAreLeftOutAndAnEmptyListIsLeftOutToo() {
        #expect(ChromePolicy.managedValues(blocklist: [], adultFilter: false).isEmpty)
        #expect(Set(ChromePolicy.managedValues(blocklist: ["a.com"], adultFilter: false).keys) == ["URLBlocklist"])
    }

    // merged keeps keys that are not SiteBlock's, replaces SiteBlock's own keys with the wanted values (a stale value of the wrong type included), and leaves nothing behind when the wanted values are empty.
    @Test func mergedReplacesEveryManagedKeyAndKeepsTheOthers() throws {
        let existing: [String: Any] = ["HomepageLocation": "https://h.example/", "SafeSitesFilterBehavior": true, "ForceGoogleSafeSearch": 1, "DnsOverHttpsMode": "secure", "URLBlocklist": ["old.com"]]
        let merged = try #require(ChromePolicy.merged(existing: existing, managed: ChromePolicy.managedValues(blocklist: [], adultFilter: true)))
        #expect(Set(merged.keys) == Set(filterKeys + ["HomepageLocation"]), "the stale URLBlocklist must go because the wanted list is empty")
        let text = try xml(merged)
        #expect(text.contains("<key>SafeSitesFilterBehavior</key>\n\t<integer>1</integer>"), "the boolean must become the integer 1")
        #expect(text.contains("<key>ForceGoogleSafeSearch</key>\n\t<true/>"), "the integer must become the boolean true")
        #expect(text.contains("<key>DnsOverHttpsMode</key>\n\t<string>off</string>"))
        #expect(merged["HomepageLocation"] as? String == "https://h.example/")
    }

    @Test func mergedWithNoWantedValuesRemovesAllFourKeysAndDeletesAnOtherwiseEmptyFile() {
        let all: [String: Any] = ["SafeSitesFilterBehavior": 1, "ForceGoogleSafeSearch": true, "DnsOverHttpsMode": "off", "URLBlocklist": ["a.com"]]
        #expect(ChromePolicy.merged(existing: all, managed: [:]) == nil)
        var withOther = all
        withOther["Other"] = "kept"
        #expect((ChromePolicy.merged(existing: withOther, managed: [:]) as NSDictionary?) == ["Other": "kept"] as NSDictionary)
    }

    @Test func mergedWithTheFilterOnNeverReturnsNilEvenWithNothingBlocked() {
        #expect(ChromePolicy.merged(existing: nil, managed: ChromePolicy.managedValues(blocklist: [], adultFilter: true)) != nil)
    }
}
