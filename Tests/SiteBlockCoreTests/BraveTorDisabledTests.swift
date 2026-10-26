import Foundation
import Testing
import SiteBlockCore

// Brave's TorDisabled policy, the pure rules only. Expected values come from Design Plans/03-daemon-cli-app.md § 13 BrowserPolicyEnforcer (the Brave line:
// "TorDisabled = true (a boolean, written as <true/>; the constant is BrowserPolicy.braveTorDisabledKey)", written "in the same group as the adult-filter keys",
// "left out only during an uninstall, which removes it like the other managed keys"; the file rules "other keys kept, SiteBlock's managed keys replaced, a file
// deleted when nothing else is left, a rewrite when a managed key differs in value or type") and 01-overview-and-data.md § How Blocking Works (Adult content filter:
// "Brave's policy file also gets TorDisabled = true"). Chrome, Edge and Firefox have no such key in the design's lists.

// True when the value is a property list boolean as opposed to a number.
private func isBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

// The key name, typed from the design.
private let tor = "TorDisabled"

// The hand edits a person could make to Brave's TorDisabled: every one leaves Tor windows available, because Brave ignores a policy of the wrong type.
enum WrongTorDisabled: CaseIterable, CustomTestStringConvertible {
    case booleanFalse, wholeNumberOne, decimalOne, textTrue, textOne, missing

    var testDescription: String { "\(self)" }

    // The value written into the file in place of the boolean true (nil removes the key).
    var value: Any? {
        switch self {
        case .booleanFalse: return false
        case .wholeNumberOne: return 1
        case .decimalOne: return 1.0
        case .textTrue: return "true"
        case .textOne: return "1"
        case .missing: return nil
        }
    }
}

@Suite struct BraveTorDisabledRuleTests {
    @Test func theConstantIsTheDesignsKeyName() {
        #expect(BrowserPolicy.braveTorDisabledKey == "TorDisabled")
    }

    @Test func braveOwnsTorDisabled() {
        #expect(BrowserTarget.brave.managedKeys.contains(tor))
    }

    // It is part of the adult-filter group, so it is wanted whether or not anything is blocked, and always as the boolean true, never the whole number 1 or text.
    @Test(arguments: [[String](), ["youtube.com"], ["youtube.com", "x.com/Home"]])
    func braveWantsTheBooleanTrueWhileTheFilterIsOnWhateverTheList(list: [String]) {
        let value = BrowserTarget.brave.managedValues(blockList: list, adultFilter: true)[tor]
        #expect(isBoolean(value), "TorDisabled must be a boolean, got \(String(describing: value)) of type \(type(of: value))")
        #expect((value as? Bool) == true)
        #expect(!(value is String))
    }

    // "left out only during an uninstall": with the filter off it is not wanted, even while a list is still wanted.
    @Test(arguments: [[String](), ["youtube.com"]])
    func braveLeavesTorDisabledOutWhenTheFilterIsOff(list: [String]) {
        let values = BrowserTarget.brave.managedValues(blockList: list, adultFilter: false)
        #expect(values[tor] == nil)
        #expect(Set(values.keys) == (list.isEmpty ? [] : ["URLBlocklist"]))
    }

    // Brave only: no other browser owns or is given the key, with the filter on or off and with or without a list.
    @Test(arguments: [BrowserTarget.chrome, .edge, .firefox])
    func noOtherBrowserOwnsOrWantsTorDisabled(target: BrowserTarget) {
        #expect(!target.managedKeys.contains(tor))
        for list in [[String](), ["youtube.com"]] {
            for filter in [true, false] { #expect(target.managedValues(blockList: list, adultFilter: filter)[tor] == nil, "\(target) list \(list) filter \(filter)") }
        }
    }

    // What a browser reads: the XML property list holds `<true/>` under the key, not `<integer>1</integer>` or `<string>`.
    @Test func braveValuesEncodeTorDisabledAsTheXMLTrue() throws {
        let values = BrowserTarget.brave.managedValues(blockList: [], adultFilter: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("<key>TorDisabled</key>\n\t<true/>"), "\(text)")
    }

    // "a rewrite when a managed key differs in value or type": a Brave file whose TorDisabled is false, the whole number 1, the decimal 1.0, the text "true" or missing
    // does not count as right, while an exact copy does.
    @Test(arguments: WrongTorDisabled.allCases)
    func aBraveFileWithAWrongOrMissingTorDisabledIsNotRight(wrong: WrongTorDisabled) {
        let wanted = BrowserTarget.brave.managedValues(blockList: ["youtube.com"], adultFilter: true)
        #expect(BrowserPolicy.sameSettings(wanted, wanted, managedKeys: BrowserTarget.brave.managedKeys), "control: an exact copy must count as right")
        var current = wanted
        current[tor] = wrong.value
        #expect(!BrowserPolicy.sameSettings(current, wanted, managedKeys: BrowserTarget.brave.managedKeys), "TorDisabled = \(wrong) counted as right")
    }

    // "other keys kept, SiteBlock's managed keys replaced": a Brave file holding only a hand-set TorDisabled = false and a company key ends up with the company key
    // and the boolean true.
    @Test func mergingReplacesAPlantedFalseAndKeepsACompanyKey() throws {
        let wanted = BrowserTarget.brave.managedValues(blockList: [], adultFilter: true)
        let merged = try #require(BrowserPolicy.merged(existing: [tor: false, "HomepageLocation": "https://intranet.example/"], managedKeys: BrowserTarget.brave.managedKeys, managed: wanted))
        #expect(merged["HomepageLocation"] as? String == "https://intranet.example/")
        #expect(isBoolean(merged[tor]) && (merged[tor] as? Bool) == true)
        #expect(Set(merged.keys) == Set(wanted.keys).union(["HomepageLocation"]))
    }

    // Uninstall ("removes it like the other managed keys", "a file deleted when nothing else is left"): with nothing wanted, TorDisabled goes and a company key stays;
    // a file holding nothing but SiteBlock's keys is deleted (nil).
    @Test func theUninstallMergeRemovesTorDisabledKeepsACompanyKeyAndDeletesAFileWithNothingElse() {
        let keys = BrowserTarget.brave.managedKeys
        let uninstall = BrowserTarget.brave.managedValues(blockList: [], adultFilter: false)
        let kept = BrowserPolicy.merged(existing: [tor: true, "ForceGoogleSafeSearch": true, "HomepageLocation": "https://intranet.example/"], managedKeys: keys, managed: uninstall)
        #expect(kept.map { Set($0.keys) } == ["HomepageLocation"])
        #expect(BrowserPolicy.merged(existing: [tor: true], managedKeys: keys, managed: uninstall) == nil)
        #expect(BrowserPolicy.merged(existing: [tor: false, "DnsOverHttpsMode": "off"], managedKeys: keys, managed: uninstall) == nil)
    }

    // TorDisabled is not Chrome's (or Edge's, or Firefox's) key, so in their files it is someone else's key: kept by a merge and by the uninstall.
    @Test(arguments: [BrowserTarget.chrome, .edge, .firefox])
    func inAnotherBrowsersFileTorDisabledIsAForeignKeyAndIsKept(target: BrowserTarget) {
        let wanted = target.managedValues(blockList: [], adultFilter: true)
        let merged = BrowserPolicy.merged(existing: [tor: true], managedKeys: target.managedKeys, managed: wanted)
        #expect(merged?[tor] as? Bool == true)
        let uninstalled = BrowserPolicy.merged(existing: [tor: true], managedKeys: target.managedKeys, managed: target.managedValues(blockList: [], adultFilter: false))
        #expect(uninstalled.map { Set($0.keys) } == [tor])
    }
}
