import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/03-daemon-cli-app.md § 13 BrowserPolicyEnforcer ("Targets and their managed keys", the 1,000-entry cap,
// "Sandbox") and § 9 (merge rules). Key names, value types and bundle names are typed here from the design, not read from the code.

// True when the value is a property list boolean as opposed to a number.
private func isBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

// True when the value is a whole number (not a boolean and not a decimal).
private func isWholeNumber(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
    return !CFNumberIsFloatType(number as CFNumber)
}

@Suite struct BrowserTargetTests {
    // 03 § 13: four targets with these preference domains.
    @Test func thereAreFourTargetsWithTheDesignsPreferenceDomains() {
        #expect(BrowserTarget.allCases.count == 4)
        #expect(BrowserTarget.chrome.bundleID == "com.google.Chrome")
        #expect(BrowserTarget.edge.bundleID == "com.microsoft.Edge")
        #expect(BrowserTarget.brave.bundleID == "com.brave.Browser")
        #expect(BrowserTarget.firefox.bundleID == "org.mozilla.firefox")
    }

    // 03 § 13: "Firefox also reads /Library/Preferences/org.mozilla.firefox.plist, so for Firefox that third file is written too".
    @Test func onlyFirefoxHasAThirdFile() {
        #expect(BrowserTarget.allCases.filter(\.alsoUsesLibraryPreferencesFile) == [.firefox])
    }

    @Test func eachTargetNamesItselfForTheLog() {
        #expect(BrowserTarget.allCases.map(\.displayName) == ["Chrome", "Edge", "Brave", "Firefox"])
    }

    // The keys each target owns, typed from 03 § 13.
    @Test func eachTargetOwnsExactlyTheKeysTheDesignGivesIt() {
        #expect(BrowserTarget.chrome.managedKeys == ["URLBlocklist", "SafeSitesFilterBehavior", "ForceGoogleSafeSearch", "DnsOverHttpsMode"])
        #expect(BrowserTarget.edge.managedKeys == ["URLBlocklist", "DnsOverHttpsMode", "ForceGoogleSafeSearch", "ForceBingSafeSearch"])
        #expect(BrowserTarget.brave.managedKeys == ["URLBlocklist", "DnsOverHttpsMode", "SafeSitesFilterBehavior", "ForceGoogleSafeSearch"])
        #expect(BrowserTarget.firefox.managedKeys == ["EnterprisePoliciesEnabled", "DNSOverHTTPS", "WebsiteFilter"])
    }

    // With the filter on and a list, every managed key is present with the design's value AND type.
    @Test func chromeValuesAreTheListAndTheThreeFilterKeysWithTheirTypes() {
        let values = BrowserTarget.chrome.managedValues(blockList: ["youtube.com"], adultFilter: true)
        #expect(Set(values.keys) == BrowserTarget.chrome.managedKeys)
        #expect(values["URLBlocklist"] as? [String] == ["youtube.com"])
        #expect(isWholeNumber(values["SafeSitesFilterBehavior"]) && (values["SafeSitesFilterBehavior"] as? Int) == 1)
        #expect(isBoolean(values["ForceGoogleSafeSearch"]) && (values["ForceGoogleSafeSearch"] as? Bool) == true)
        #expect(values["DnsOverHttpsMode"] as? String == "off")
    }

    // 03 § 13: "Edge — URLBlocklist, DnsOverHttpsMode = "off", ForceGoogleSafeSearch = true, ForceBingSafeSearch = 2 (strict)". "ForceBingSafeSearch is an integer, 2."
    @Test func edgeValuesIncludeBingSafeSearchAsTheIntegerTwo() {
        let values = BrowserTarget.edge.managedValues(blockList: ["youtube.com/shorts"], adultFilter: true)
        #expect(Set(values.keys) == BrowserTarget.edge.managedKeys)
        #expect(values["URLBlocklist"] as? [String] == ["youtube.com/shorts"])
        #expect(values["DnsOverHttpsMode"] as? String == "off")
        #expect(isBoolean(values["ForceGoogleSafeSearch"]) && (values["ForceGoogleSafeSearch"] as? Bool) == true)
        #expect(isWholeNumber(values["ForceBingSafeSearch"]) && (values["ForceBingSafeSearch"] as? Int) == 2)
        #expect(values["SafeSitesFilterBehavior"] == nil, "Edge does not get the Chrome-only key")
    }

    @Test func braveValuesAreTheListSecureDNSOffSafeSitesAndGoogleSafeSearch() {
        let values = BrowserTarget.brave.managedValues(blockList: ["youtube.com"], adultFilter: true)
        #expect(Set(values.keys) == BrowserTarget.brave.managedKeys)
        #expect(values["DnsOverHttpsMode"] as? String == "off")
        #expect(isWholeNumber(values["SafeSitesFilterBehavior"]) && (values["SafeSitesFilterBehavior"] as? Int) == 1)
        #expect(isBoolean(values["ForceGoogleSafeSearch"]) && (values["ForceGoogleSafeSearch"] as? Bool) == true)
        #expect(values["ForceBingSafeSearch"] == nil)
    }

    // 03 § 13: Firefox "EnterprisePoliciesEnabled = true, DNSOverHTTPS = {Enabled: false, Locked: true}, WebsiteFilter = {Block: [...]}"; the two dictionaries are nested.
    @Test func firefoxValuesAreNestedDictionariesWithBooleansInside() throws {
        let values = BrowserTarget.firefox.managedValues(blockList: ["*://*.youtube.com/*"], adultFilter: true)
        #expect(Set(values.keys) == BrowserTarget.firefox.managedKeys)
        #expect(isBoolean(values["EnterprisePoliciesEnabled"]) && (values["EnterprisePoliciesEnabled"] as? Bool) == true)
        let doh = try #require(values["DNSOverHTTPS"] as? [String: Any])
        #expect(Set(doh.keys) == ["Enabled", "Locked"])
        #expect(isBoolean(doh["Enabled"]) && (doh["Enabled"] as? Bool) == false)
        #expect(isBoolean(doh["Locked"]) && (doh["Locked"] as? Bool) == true)
        let filter = try #require(values["WebsiteFilter"] as? [String: Any])
        #expect(Set(filter.keys) == ["Block"])
        #expect(filter["Block"] as? [String] == ["*://*.youtube.com/*"])
    }

    // The nested dictionaries survive being written as a property list and read back, which is what a browser does.
    @Test func firefoxValuesSurviveAPropertyListRoundTripWithTheirTypes() throws {
        let values = BrowserTarget.firefox.managedValues(blockList: ["*://*.a.com/*"], adultFilter: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        let back = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(BrowserPolicy.strictlyEqual(back, values))
        let doh = try #require(back["DNSOverHTTPS"] as? [String: Any])
        #expect(isBoolean(doh["Enabled"]) && isBoolean(doh["Locked"]))
    }

    // 03 § 13: "URLBlocklist and WebsiteFilter are left out when their list is empty." The filter keys stay.
    @Test(arguments: BrowserTarget.allCases)
    func anEmptyListLeavesOutTheListKeyButKeepsEveryFilterKey(target: BrowserTarget) {
        let values = target.managedValues(blockList: [], adultFilter: true)
        let listKey = target == .firefox ? "WebsiteFilter" : "URLBlocklist"
        #expect(values[listKey] == nil)
        #expect(Set(values.keys) == target.managedKeys.subtracting([listKey]))
    }

    // During an uninstall the filter is off and the lists are empty: nothing is wanted, so every managed key is removed from the file.
    @Test(arguments: BrowserTarget.allCases)
    func withTheFilterOffAndNoListNothingIsWanted(target: BrowserTarget) {
        #expect(target.managedValues(blockList: [], adultFilter: false).isEmpty)
    }

    // The list part for each target: Chrome, Edge and Brave use the Chrome-format lists, Firefox the match patterns.
    @Test func eachTargetTakesItsOwnFormatOfTheLists() {
        let lists = BrowserBlockLists(chromeSites: ["a.com"], chromePaths: ["a.com/x"], firefoxSites: ["*://*.a.com/*"], firefoxPaths: ["*://*.a.com/x*"])
        for target in [BrowserTarget.chrome, .edge, .brave] {
            #expect(target.lists(from: lists).sites == ["a.com"] && target.lists(from: lists).paths == ["a.com/x"])
        }
        #expect(BrowserTarget.firefox.lists(from: lists).sites == ["*://*.a.com/*"])
        #expect(BrowserTarget.firefox.lists(from: lists).paths == ["*://*.a.com/x*"])
    }
}

@Suite struct BrowserPolicyMergeTests {
    // 03 § 9 (merged): keeps every key that is not managed, removes every managed key, adds the managed values; nil when nothing is left.
    @Test func foreignKeysAreKeptAndManagedKeysAreReplaced() {
        let existing: [String: Any] = ["HomepageLocation": "https://home.example/", "URLBlocklist": ["stale.example"], "DnsOverHttpsMode": "automatic"]
        let managed: [String: Any] = ["URLBlocklist": ["youtube.com"], "DnsOverHttpsMode": "off"]
        let merged = BrowserPolicy.merged(existing: existing, managedKeys: BrowserTarget.chrome.managedKeys, managed: managed)
        #expect(merged?["HomepageLocation"] as? String == "https://home.example/")
        #expect(merged?["URLBlocklist"] as? [String] == ["youtube.com"])
        #expect(merged?["DnsOverHttpsMode"] as? String == "off")
        #expect(merged?.count == 3)
    }

    // A managed key that is no longer wanted is removed, not left stale.
    @Test func aManagedKeyThatIsNotWantedAnyMoreIsRemoved() {
        let existing: [String: Any] = ["Keep": 1, "WebsiteFilter": ["Block": ["*://*.old.com/*"]], "DNSOverHTTPS": ["Enabled": true]]
        let merged = BrowserPolicy.merged(existing: existing, managedKeys: BrowserTarget.firefox.managedKeys, managed: [:])
        #expect(merged?.count == 1 && merged?["Keep"] as? Int == 1)
    }

    @Test func whenNothingIsLeftTheResultIsNilMeaningDeleteTheFile() {
        #expect(BrowserPolicy.merged(existing: nil, managedKeys: BrowserTarget.firefox.managedKeys, managed: [:]) == nil)
        #expect(BrowserPolicy.merged(existing: ["EnterprisePoliciesEnabled": true], managedKeys: BrowserTarget.firefox.managedKeys, managed: [:]) == nil)
    }

    @Test func aMissingFileCountsAsEmptyAndGetsTheManagedKeys() {
        let managed = BrowserTarget.edge.managedValues(blockList: [], adultFilter: true)
        let merged = BrowserPolicy.merged(existing: nil, managedKeys: BrowserTarget.edge.managedKeys, managed: managed)
        #expect(merged.map { Set($0.keys) } == BrowserTarget.edge.managedKeys.subtracting(["URLBlocklist"]))
    }

    // Another browser's keys are not this browser's: Firefox's merge leaves Chrome-style keys alone (they are foreign to it).
    @Test func aKeyThatBelongsToAnotherBrowserIsForeignAndKept() {
        let merged = BrowserPolicy.merged(existing: ["URLBlocklist": ["x.com"]], managedKeys: BrowserTarget.firefox.managedKeys, managed: ["EnterprisePoliciesEnabled": true])
        #expect(merged?["URLBlocklist"] as? [String] == ["x.com"])
    }

    // The Chrome-only helper still behaves the same through the shared merge.
    @Test func chromePolicyMergedStillMergesTheSameWay() {
        let merged = ChromePolicy.merged(existing: ["Other": "x", "URLBlocklist": ["old"]], managed: ["URLBlocklist": ["new.com"]])
        #expect(merged?["Other"] as? String == "x" && merged?["URLBlocklist"] as? [String] == ["new.com"])
    }
}

@Suite struct BrowserPolicyCapTests {
    // 03 § 13: "Each list is capped at 1,000 entries (both browsers ignore the rest)".
    @Test func theCapIs1000() {
        #expect(BrowserPolicy.maxListEntries == 1000)
    }

    @Test func aShortListIsReturnedSortedAndUncut() {
        let result = BrowserPolicy.capped(sites: ["b.com", "a.com"], paths: ["a.com/x"])
        #expect(result.list == ["a.com", "a.com/x", "b.com"])
        #expect(result.droppedCount == 0)
    }

    @Test func exactlyTheLimitIsNotCut() {
        let sites = (0..<600).map { String(format: "s%04d.com", $0) }
        let paths = (0..<400).map { String(format: "p%04d.com/x", $0) }
        let result = BrowserPolicy.capped(sites: sites, paths: paths)
        #expect(result.list.count == 1000 && result.droppedCount == 0)
    }

    // "cut to 1,000 with whole-site entries kept first": with 700 sites and 600 paths, all 700 sites stay and only 300 paths do.
    @Test func aLongListKeepsEveryWholeSiteEntryBeforeAnyPathEntry() {
        let sites = (0..<700).map { String(format: "s%04d.com", $0) }
        let paths = (0..<600).map { String(format: "a%04d.com/x", $0) }
        let result = BrowserPolicy.capped(sites: sites, paths: paths)
        #expect(result.list.count == 1000)
        #expect(result.droppedCount == 300)
        #expect(Set(sites).isSubset(of: Set(result.list)), "every whole-site entry must survive")
        #expect(result.list.filter { $0.contains("/") }.count == 300)
        // The 300 path entries kept are the first 300 in sorted order, so the result is the same on every pass.
        #expect(Set(result.list.filter { $0.contains("/") }) == Set(paths.sorted().prefix(300)))
        #expect(result.list == result.list.sorted())
    }

    // Even when the whole-site entries alone are too many, the cut is still exactly 1,000 and sorted.
    @Test func moreThanTheLimitOfWholeSitesIsCutToTheLimit() {
        let sites = (0..<1200).map { String(format: "s%04d.com", $0) }
        let result = BrowserPolicy.capped(sites: sites, paths: ["a.com/x"])
        #expect(result.list.count == 1000 && result.droppedCount == 201)
        #expect(!result.list.contains("a.com/x"), "paths are cut first")
    }

    @Test func aCustomLimitWorksAndZeroKeepsNothing() {
        #expect(BrowserPolicy.capped(sites: ["a.com", "b.com"], paths: ["a.com/x"], limit: 2).list == ["a.com", "b.com"])
        let none = BrowserPolicy.capped(sites: ["a.com"], paths: [], limit: 0)
        #expect(none.list.isEmpty && none.droppedCount == 1)
    }
}

@Suite struct BrowserPolicySameSettingsTests {
    private let keys = BrowserTarget.firefox.managedKeys
    private var wanted: [String: Any] { BrowserTarget.firefox.managedValues(blockList: ["*://*.a.com/*"], adultFilter: true) }

    @Test func identicalSettingsAreTheSame() {
        #expect(BrowserPolicy.sameSettings(wanted, wanted, managedKeys: keys))
    }

    // Foundation says true == 1 and 1 == 1.0, but a browser ignores a policy of the wrong type, so each swap must count as a difference.
    @Test func aBooleanSwappedForANumberIsADifference() {
        var tampered = wanted
        tampered["EnterprisePoliciesEnabled"] = 1
        #expect(!BrowserPolicy.sameSettings(tampered, wanted, managedKeys: keys))
    }

    @Test func nestedBooleansSwappedForNumbersAreADifference() {
        var tampered = wanted
        tampered["DNSOverHTTPS"] = ["Enabled": 0, "Locked": 1] as [String: Any]
        #expect(!BrowserPolicy.sameSettings(tampered, wanted, managedKeys: keys))
    }

    @Test func aNestedValueChangedIsADifference() {
        var tampered = wanted
        tampered["DNSOverHTTPS"] = ["Enabled": true, "Locked": true] as [String: Any]
        #expect(!BrowserPolicy.sameSettings(tampered, wanted, managedKeys: keys))
        tampered["DNSOverHTTPS"] = ["Enabled": false, "Locked": false] as [String: Any]
        #expect(!BrowserPolicy.sameSettings(tampered, wanted, managedKeys: keys))
    }

    @Test func aNestedKeyAddedOrMissingIsADifference() {
        var tampered = wanted
        tampered["DNSOverHTTPS"] = ["Enabled": false, "Locked": true, "ProviderURL": "https://x.example/"] as [String: Any]
        #expect(!BrowserPolicy.sameSettings(tampered, wanted, managedKeys: keys))
        tampered["DNSOverHTTPS"] = ["Enabled": false] as [String: Any]
        #expect(!BrowserPolicy.sameSettings(tampered, wanted, managedKeys: keys))
    }

    @Test func aWholeNumberSwappedForADecimalNumberIsADifference() {
        let edgeKeys = BrowserTarget.edge.managedKeys
        let edgeWanted = BrowserTarget.edge.managedValues(blockList: [], adultFilter: true)
        var tampered = edgeWanted
        tampered["ForceBingSafeSearch"] = 2.0
        #expect(!BrowserPolicy.sameSettings(tampered, edgeWanted, managedKeys: edgeKeys))
        tampered["ForceBingSafeSearch"] = 1
        #expect(!BrowserPolicy.sameSettings(tampered, edgeWanted, managedKeys: edgeKeys))
        #expect(BrowserPolicy.sameSettings(edgeWanted, edgeWanted, managedKeys: edgeKeys))
    }

    @Test func aListThatDiffersInOrderOrContentIsADifference() {
        let chromeKeys = BrowserTarget.chrome.managedKeys
        let base = BrowserTarget.chrome.managedValues(blockList: ["a.com", "b.com"], adultFilter: true)
        var reordered = base
        reordered["URLBlocklist"] = ["b.com", "a.com"]
        #expect(!BrowserPolicy.sameSettings(reordered, base, managedKeys: chromeKeys))
        var shorter = base
        shorter["URLBlocklist"] = ["a.com"]
        #expect(!BrowserPolicy.sameSettings(shorter, base, managedKeys: chromeKeys))
        var wrongType = base
        wrongType["URLBlocklist"] = "a.com"
        #expect(!BrowserPolicy.sameSettings(wrongType, base, managedKeys: chromeKeys))
    }

    // A key present in one and missing in the other is a difference in both directions, and foreign keys that are equal do not matter.
    @Test func missingAndExtraKeysAreDifferencesAndEqualForeignKeysAreNot() {
        var withForeign = wanted
        withForeign["Homepage"] = ["URL": "https://x.example/"] as [String: Any]
        #expect(!BrowserPolicy.sameSettings(withForeign, wanted, managedKeys: keys))
        #expect(!BrowserPolicy.sameSettings(wanted, withForeign, managedKeys: keys))
        #expect(BrowserPolicy.sameSettings(withForeign, withForeign, managedKeys: keys))
        var missing = wanted
        missing.removeValue(forKey: "WebsiteFilter")
        #expect(!BrowserPolicy.sameSettings(missing, wanted, managedKeys: keys))
    }

    @Test func strictlyEqualHandlesNilTextDatesAndData() {
        #expect(BrowserPolicy.strictlyEqual(nil, nil))
        #expect(!BrowserPolicy.strictlyEqual(nil, "x"))
        #expect(!BrowserPolicy.strictlyEqual("x", nil))
        #expect(BrowserPolicy.strictlyEqual("off", "off"))
        #expect(!BrowserPolicy.strictlyEqual("off", "on"))
        #expect(!BrowserPolicy.strictlyEqual("1", 1))
        #expect(BrowserPolicy.strictlyEqual(Date(timeIntervalSince1970: 5), Date(timeIntervalSince1970: 5)))
        #expect(!BrowserPolicy.strictlyEqual(Date(timeIntervalSince1970: 5), Date(timeIntervalSince1970: 6)))
        #expect(BrowserPolicy.strictlyEqual(Data([1, 2]), Data([1, 2])))
        #expect(!BrowserPolicy.strictlyEqual(Data([1, 2]), Data([1, 3])))
        #expect(!BrowserPolicy.strictlyEqual(["a"], "a"))
    }
}
