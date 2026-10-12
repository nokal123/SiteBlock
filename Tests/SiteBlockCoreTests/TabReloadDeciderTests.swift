import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § 3c TabReloadDecider (the memory per process id and tab id, the five per-tab rules of
// tabsToReload, forgetProcesses(except:), forgetAll, remembered) and from 05-testing-and-operations.md § Unit Tests (TabReloadDeciderTests). Whether an address
// falls under a rule is the matcher's job (§ 3b), so the addresses here are chosen so that the answer is clear from the design alone: with the rule
// youtube.com + /shorts, an address on youtube.com whose path starts with /shorts is "blocked", and anything else is "open".

private let shortsRule = WatchedPathRule(domain: "youtube.com", path: "/shorts")
private let exampleRule = WatchedPathRule(domain: "example.com", path: "/shorts")
private let rules = [shortsRule]

// Blocked addresses (they fall under the rule youtube.com/shorts) and open ones (they do not).
private func blocked(_ n: Int) -> String { "https://www.youtube.com/shorts/v\(n)" }
private let openWatch = "https://www.youtube.com/watch?v=1"
private let openHome = "https://www.youtube.com/"
private let newTab = "chrome://newtab/"

// Builds one entry of a tab list the way the tab watcher passes it in.
private func tab(_ id: String, _ url: String) -> (id: String, url: String) { (id: id, url: url) }

// A small seeded random generator (SplitMix64) so the generated sequences are repeatable.
private struct DeciderGenerator: RandomNumberGenerator {
    var state: UInt64
    // Produces the next 64 random bits.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - acting once per tab and address

@Suite struct TabReloadDeciderActOnceTests {
    // "A tab on a blocked address is returned once, and an identical second call returns nothing while remembered still holds the address."
    @Test func aBlockedTabIsReturnedOnceAndThenLeftAlone() {
        var decider = TabReloadDecider()
        #expect(decider.remembered(processID: 100) == [:])
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("t1", blocked(1))], rules: rules) == ["t1"])
        #expect(decider.remembered(processID: 100) == ["t1": blocked(1)])
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("t1", blocked(1))], rules: rules) == [])
        #expect(decider.remembered(processID: 100) == ["t1": blocked(1)])
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("t1", blocked(1))], rules: rules) == [])
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("t1", blocked(1))], rules: rules) == [])
        #expect(decider.remembered(processID: 100) == ["t1": blocked(1)])
    }

    // "A tab that moves from one blocked address to a different blocked address is returned again", and the new address is the one remembered.
    @Test func aTabThatMovesToAnotherBlockedAddressIsReturnedAgain() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t1", blocked(1))], rules: rules) == ["t1"])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t1", blocked(2))], rules: rules) == ["t1"])
        #expect(decider.remembered(processID: 1) == ["t1": blocked(2)])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t1", blocked(2))], rules: rules) == [])
        // Going back to the first address is a change again.
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t1", blocked(1))], rules: rules) == ["t1"])
        #expect(decider.remembered(processID: 1) == ["t1": blocked(1)])
    }

    // The address is compared as written, including its query and fragment: a different text is a different address.
    @Test func anAddressThatDiffersOnlyInItsQueryOrFragmentCountsAsDifferent() {
        var decider = TabReloadDecider()
        let a = "https://youtube.com/shorts/abc?feature=share"
        let b = "https://youtube.com/shorts/abc?feature=other"
        let c = "https://youtube.com/shorts/abc#t=5"
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t", a)], rules: rules) == ["t"])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t", a)], rules: rules) == [])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t", b)], rules: rules) == ["t"])
        #expect(decider.remembered(processID: 1) == ["t": b])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t", c)], rules: rules) == ["t"])
        #expect(decider.remembered(processID: 1) == ["t": c])
    }

    // The address is compared and remembered exactly as written, letter for letter: a pair that differs only in letter case (in the path, in the host, or in the
    // hex digits of a percent-escape) is two addresses. Sitting on the first address does not reload again (a decider that remembers a lowercased copy and compares
    // the raw text would reload on every call), and moving between the two reloads (a case-insensitive compare would stay quiet).
    @Test(arguments: [
        ("https://youtube.com/shorts/aBcDeF_-12", "https://youtube.com/shorts/abcdef_-12"),
        ("https://youtube.com/shorts/abcdef_-12", "https://youtube.com/shorts/aBcDeF_-12"),
        ("https://youtube.com/shorts/a%20b%2Fc%E6%97%A5", "https://youtube.com/shorts/a%20b%2fc%e6%97%a5"),
        ("https://YouTube.com/shorts/x", "https://youtube.com/shorts/x"),
        ("https://www.youtube.com/shorts/X-1", "https://www.youtube.com/shorts/x-1"),
    ])
    func addressesThatDifferOnlyInLetterCaseAreDifferentAddresses(first: String, second: String) {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t", first)], rules: rules) == ["t"])
        #expect(decider.remembered(processID: 1) == ["t": first], "the address is remembered as written")
        for _ in 0..<3 {
            #expect(decider.tabsToReload(processID: 1, tabs: [tab("t", first)], rules: rules) == [], "the same text must not reload again")
            #expect(decider.remembered(processID: 1) == ["t": first])
        }
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t", second)], rules: rules) == ["t"], "a change of letter case is a change of address")
        #expect(decider.remembered(processID: 1) == ["t": second])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t", second)], rules: rules) == [])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t", first)], rules: rules) == ["t"])
    }

    // Addresses with mixed case, percent-escapes and non-ASCII letters or symbols in the path are remembered as written and acted on once. (They all start with
    // /shorts on youtube.com, so they match the rule; the matcher is tested on its own elsewhere.)
    @Test(arguments: [
        "https://youtube.com/shorts/aBcDeF_-12",
        "https://YOUTUBE.COM/shorts/AbC",
        "https://www.youtube.com/shorts/a%20b%2Fc%E6%97%A5",
        "https://www.youtube.com/shorts/%E6%97%A5%E6%9C%AC%E8%AA%9E?x=%2F#%41",
        "https://youtube.com/shorts/日本語",
        "https://youtube.com/shorts/ünïcödé-ÄÖÜ",
        "https://youtube.com/shorts/😀",
        "https://youtube.com/shorts/a b",
        "https://youtube.com/shorts/aBc_-.~!$&'()*+,;=:@",
    ])
    func aMixedCaseEscapedOrNonAsciiAddressIsRememberedAsWrittenAndActedOnOnce(url: String) {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 3, tabs: [tab("t", url)], rules: rules) == ["t"], "\(url) must be acted on")
        #expect(decider.remembered(processID: 3) == ["t": url])
        for _ in 0..<3 {
            #expect(decider.tabsToReload(processID: 3, tabs: [tab("t", url)], rules: rules) == [], "\(url) must not be acted on twice")
            #expect(decider.remembered(processID: 3) == ["t": url])
        }
        // Leaving and coming back acts again, as for any other address.
        #expect(decider.tabsToReload(processID: 3, tabs: [tab("t", openHome)], rules: rules) == [])
        #expect(decider.tabsToReload(processID: 3, tabs: [tab("t", url)], rules: rules) == ["t"])
    }

    // "When it does not match, the memory for that tab is dropped, so going back to the blocked part later reloads the tab again."
    @Test func aTabThatLeavesTheBlockedPartAndComesBackIsReturnedAgain() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t1", blocked(1))], rules: rules) == ["t1"])
        // Leaves to an open address: nothing to reload, and the memory is gone.
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t1", openWatch)], rules: rules) == [])
        #expect(decider.remembered(processID: 1) == [:])
        // Comes back to the very same blocked address: acted on again.
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("t1", blocked(1))], rules: rules) == ["t1"])
        #expect(decider.remembered(processID: 1) == ["t1": blocked(1)])
    }

    // The way out can be any non-matching address: another site, the site's own home page, a browser page, an unparseable text.
    @Test(arguments: ["https://example.org/", "https://www.youtube.com/", "https://www.youtube.com/watch?v=1", "chrome://newtab/", "about:blank", "", "not a url", "https://youtube.com/short"])
    func leavingToAnyOpenAddressForgetsTheTab(open: String) {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 5, tabs: [tab("t", blocked(1))], rules: rules) == ["t"])
        #expect(decider.tabsToReload(processID: 5, tabs: [tab("t", open)], rules: rules) == [])
        #expect(decider.remembered(processID: 5) == [:], "\(open.debugDescription) does not match the rule, so the tab is forgotten")
        #expect(decider.tabsToReload(processID: 5, tabs: [tab("t", blocked(1))], rules: rules) == ["t"])
    }

    // "Tabs that do not match are never returned and are not remembered."
    @Test func tabsThatDoNotMatchAreNeverReturnedOrRemembered() {
        var decider = TabReloadDecider()
        let tabs = [tab("a", openWatch), tab("b", openHome), tab("c", newTab), tab("d", "https://example.com/shorts"), tab("e", "")]
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == [])
        #expect(decider.remembered(processID: 1) == [:])
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == [])
        #expect(decider.remembered(processID: 1) == [:])
    }

    // A mixed list: only the matching tab is returned and remembered, the others are neither.
    @Test func onlyTheMatchingTabsOfAMixedListAreReturnedAndRemembered() {
        var decider = TabReloadDecider()
        let tabs = [tab("a", openWatch), tab("b", blocked(2)), tab("c", newTab), tab("d", blocked(4)), tab("e", openHome)]
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == ["b", "d"])
        #expect(decider.remembered(processID: 1) == ["b": blocked(2), "d": blocked(4)])
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == [])
    }

    // "several matching tabs are returned together in input order": ids that do not sort the way they were given, so a sorted or reversed answer fails.
    @Test func severalMatchingTabsAreReturnedTogetherInInputOrder() {
        var decider = TabReloadDecider()
        let ids = ["9", "3", "7", "10", "1", "b", "A", "a", "zz", "2"]
        let tabs = ids.enumerated().map { tab($0.element, blocked($0.offset)) }
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == ids)
        // A new list in another order: the answer follows the new order, for the tabs whose address changed.
        let reordered = Array(tabs.reversed()).map { tab($0.id, $0.url + "x") }
        #expect(decider.tabsToReload(processID: 1, tabs: reordered, rules: rules) == Array(ids.reversed()))
    }

    // The returned order is the input order even when memory suppresses some tabs in the middle.
    @Test func suppressedTabsDoNotDisturbTheOrderOfTheOthers() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("b", blocked(2)), tab("d", blocked(4))], rules: rules) == ["b", "d"])
        let tabs = [tab("e", blocked(5)), tab("d", blocked(4)), tab("c", blocked(3)), tab("b", blocked(2)), tab("a", blocked(1))]
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == ["e", "c", "a"])
    }

    // Many tabs at once: every blocked one comes back once, in order, and none the second time.
    @Test func aLongTabListIsHandledInOrderAndOnlyOnce() {
        var decider = TabReloadDecider()
        let tabs = (0..<5_000).map { n in n % 3 == 0 ? tab("tab\(n)", openWatch) : tab("tab\(n)", blocked(n)) }
        let expected = (0..<5_000).filter { $0 % 3 != 0 }.map { "tab\($0)" }
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == expected)
        #expect(decider.remembered(processID: 1).count == expected.count)
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == [])
    }

    // An empty tab list returns nothing and, as every remembered tab is missing from it, forgets them all.
    @Test func anEmptyTabListReturnsNothingAndForgetsEverything() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2))], rules: rules) == ["a", "b"])
        #expect(decider.tabsToReload(processID: 1, tabs: [], rules: rules) == [])
        #expect(decider.remembered(processID: 1) == [:])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2))], rules: rules) == ["a", "b"])
    }

    // A call for a process that was never seen, with an empty list, is harmless.
    @Test func anEmptyListForAnUnknownProcessIsHarmless() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 77, tabs: [], rules: rules) == [])
        #expect(decider.remembered(processID: 77) == [:])
    }

    // Tab ids are plain strings compared exactly: case, leading zeros, an empty id, a space and non-ASCII ids are all different tabs.
    @Test func tabIdsAreComparedExactly() {
        var decider = TabReloadDecider()
        let ids = ["a", "A", "1", "01", "", " ", "日本", "é"]
        let tabs = ids.map { tab($0, blocked(1)) }
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == ids)
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == [])
        #expect(decider.remembered(processID: 1).count == ids.count)
    }

    // A tab id that is one character longer or shorter is a different tab.
    @Test func idsThatDifferByOneCharacterAreDifferentTabs() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("12", blocked(1))], rules: rules) == ["12"])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("12", blocked(1)), tab("123", blocked(1)), tab("1", blocked(1))], rules: rules) == ["123", "1"])
    }
}

// MARK: - tabs that disappear

@Suite struct TabReloadDeciderMissingTabTests {
    // "A tab ID missing from the list loses its memory, so the same tab reappearing on the same blocked address is returned again."
    @Test func aTabMissingFromTheListIsForgottenAndActedOnAgainWhenItReturns() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2))], rules: rules) == ["a", "b"])
        // "a" closed: only "b" is listed, and "b" is left alone.
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("b", blocked(2))], rules: rules) == [])
        #expect(decider.remembered(processID: 1) == ["b": blocked(2)])
        // The id "a" is used again on the same address: it is a new tab, so it is returned, and "b" is still remembered.
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2))], rules: rules) == ["a"])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1), "b": blocked(2)])
    }

    // The list is the complete picture: when the tab is not in it (only an unrelated open tab is), its memory is gone, so the tab acts again when it returns.
    @Test func aTabReplacedByAnUnrelatedOpenTabActsAgainWhenItReturns() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: rules) == ["a"])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("z", openHome)], rules: rules) == [])
        #expect(decider.remembered(processID: 1) == [:])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: rules) == ["a"])
    }

    // Memory for a tab that is missing is dropped even if the list that replaced it holds only tabs that do not match.
    @Test func aListOfOnlyOpenTabsStillDropsTheMissingBlockedOne() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2)), tab("c", blocked(3))], rules: rules) == ["a", "b", "c"])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("x", openWatch), tab("y", newTab)], rules: rules) == [])
        #expect(decider.remembered(processID: 1) == [:])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2)), tab("c", blocked(3))], rules: rules) == ["a", "b", "c"])
    }
}

// MARK: - process separation

@Suite struct TabReloadDeciderProcessTests {
    // "Memory is per process: the same tab ID in two processes is tracked separately, and a call for one process leaves the other's memory unchanged."
    @Test func theSameTabIdInTwoProcessesIsTrackedSeparately() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("1", blocked(1))], rules: rules) == ["1"])
        // Another process uses the same id on the same address: still new for that process.
        #expect(decider.tabsToReload(processID: 200, tabs: [tab("1", blocked(1))], rules: rules) == ["1"])
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("1", blocked(1))], rules: rules) == [])
        #expect(decider.tabsToReload(processID: 200, tabs: [tab("1", blocked(1))], rules: rules) == [])
        #expect(decider.remembered(processID: 100) == ["1": blocked(1)])
        #expect(decider.remembered(processID: 200) == ["1": blocked(1)])
    }

    // A call for one process leaves another process's memory exactly as it was, whatever that call does to its own.
    @Test func aCallForOneProcessLeavesTheOthersMemoryUnchanged() {
        var decider = TabReloadDecider()
        _ = decider.tabsToReload(processID: 100, tabs: [tab("1", blocked(1)), tab("2", blocked(2))], rules: rules)
        _ = decider.tabsToReload(processID: 200, tabs: [tab("1", blocked(9))], rules: rules)
        let before100 = decider.remembered(processID: 100)
        let before200 = decider.remembered(processID: 200)
        // Process 100 moves one tab, closes the other, and opens a new one.
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("1", blocked(3)), tab("3", blocked(4))], rules: rules) == ["1", "3"])
        #expect(decider.remembered(processID: 200) == before200)
        // Process 200 leaves the blocked part.
        #expect(decider.tabsToReload(processID: 200, tabs: [tab("1", openHome)], rules: rules) == [])
        #expect(decider.remembered(processID: 100) == ["1": blocked(3), "3": blocked(4)])
        #expect(before100 == ["1": blocked(1), "2": blocked(2)])
        #expect(before200 == ["1": blocked(9)])
    }

    // "A process omitted from a call keeps its memory": a tick that could not read process 100 does not pass it in, and a later read continues from its memory.
    @Test func aProcessThatIsNotPassedInKeepsItsMemory() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("1", blocked(1))], rules: rules) == ["1"])
        for tick in 0..<5 {
            #expect(decider.tabsToReload(processID: 200, tabs: [tab("9", blocked(9))], rules: rules) == (tick == 0 ? ["9"] : []))
            #expect(decider.remembered(processID: 100) == ["1": blocked(1)])
        }
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("1", blocked(1))], rules: rules) == [])
        #expect(decider.remembered(processID: 100) == ["1": blocked(1)])
    }

    // Process ids that are zero, negative, or at the ends of the Int32 range are ordinary distinct keys.
    @Test func extremeProcessIdsAreOrdinaryDistinctKeys() {
        var decider = TabReloadDecider()
        let pids: [Int32] = [0, -1, 1, Int32.max, Int32.min, Int32.max - 1, Int32.min + 1]
        for (i, pid) in pids.enumerated() {
            #expect(decider.tabsToReload(processID: pid, tabs: [tab("t", blocked(i))], rules: rules) == ["t"], "pid \(pid)")
        }
        for (i, pid) in pids.enumerated() {
            #expect(decider.remembered(processID: pid) == ["t": blocked(i)], "pid \(pid)")
            #expect(decider.tabsToReload(processID: pid, tabs: [tab("t", blocked(i))], rules: rules) == [], "pid \(pid)")
        }
    }

    // remembered(processID:) for a process that never had anything is empty, not a crash.
    @Test func rememberedForAnUnknownProcessIsEmpty() {
        var decider = TabReloadDecider()
        #expect(decider.remembered(processID: 123) == [:])
        _ = decider.tabsToReload(processID: 1, tabs: [tab("t", blocked(1))], rules: rules)
        #expect(decider.remembered(processID: 123) == [:])
        #expect(decider.remembered(processID: Int32.min) == [:])
    }
}

// MARK: - rules

@Suite struct TabReloadDeciderRuleTests {
    // "With an empty rule list nothing is returned and that process's memory is cleared, while other processes keep theirs."
    @Test func noRulesReturnsNothingAndClearsOnlyThatProcess() {
        var decider = TabReloadDecider()
        _ = decider.tabsToReload(processID: 100, tabs: [tab("1", blocked(1))], rules: rules)
        _ = decider.tabsToReload(processID: 200, tabs: [tab("1", blocked(1)), tab("2", blocked(2))], rules: rules)
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("1", blocked(1)), tab("5", blocked(5))], rules: []) == [])
        #expect(decider.remembered(processID: 100) == [:])
        #expect(decider.remembered(processID: 200) == ["1": blocked(1), "2": blocked(2)])
        // Process 100's tab is now acted on again once rules exist; process 200 is untouched.
        #expect(decider.tabsToReload(processID: 100, tabs: [tab("1", blocked(1))], rules: rules) == ["1"])
        #expect(decider.tabsToReload(processID: 200, tabs: [tab("1", blocked(1)), tab("2", blocked(2))], rules: rules) == [])
    }

    // With no rules nothing is ever returned, for blocked-looking tabs, many tabs, and an empty tab list, for a process that has memory or does not.
    @Test func noRulesNeverReturnsAnything() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2))], rules: []) == [])
        #expect(decider.remembered(processID: 1) == [:])
        #expect(decider.tabsToReload(processID: 1, tabs: [], rules: []) == [])
        #expect(decider.tabsToReload(processID: 2, tabs: (0..<100).map { tab("t\($0)", blocked($0)) }, rules: []) == [])
        #expect(decider.remembered(processID: 2) == [:])
    }

    // After the rules disappear and come back, a tab that stayed on the blocked address is acted on again (the memory was cleared).
    @Test func rulesThatGoAwayAndReturnMakeATabActAgain() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: rules) == ["a"])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: []) == [])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: rules) == ["a"])
    }

    // The memory is of the address, not of the rule: a second rule that also matches the same address does not make the tab act again.
    @Test func anExtraRuleThatAlsoMatchesTheSameAddressDoesNotActAgain() {
        var decider = TabReloadDecider()
        let broader = WatchedPathRule(domain: "youtube.com", path: "/sh")
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: [shortsRule]) == ["a"])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: [shortsRule, broader]) == [])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: [broader]) == [])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1)])
    }

    // A rule change that stops matching the tab's address drops its memory; when a matching rule returns, the tab is acted on again.
    @Test func aRuleChangeThatNoLongerMatchesTheAddressForgetsTheTab() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: [shortsRule]) == ["a"])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: [exampleRule]) == [])
        #expect(decider.remembered(processID: 1) == [:])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: [exampleRule, shortsRule]) == ["a"])
    }

    // Any rule in the list can make a tab match, in any position.
    @Test func aTabMatchingAnyRuleInTheListIsReturned() {
        var decider = TabReloadDecider()
        let tabs = [tab("y", blocked(1)), tab("e", "https://example.com/shorts/x"), tab("o", "https://other.org/shorts")]
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: [exampleRule, shortsRule]) == ["y", "e"])
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: [shortsRule, exampleRule]) == [])
    }
}

// MARK: - duplicates

// 02 § 3c "Repeated tab id": a browser never lists the same tab id twice in one answer, but when a list does, the tab is handled once, by its FIRST appearance. That
// appearance decides whether the id is returned and which address is remembered; later appearances are ignored, whatever their address.
@Suite struct TabReloadDeciderDuplicateTests {
    // The same id twice at the same blocked address: returned once, remembered once; a third and fourth copy change nothing.
    @Test func aRepeatedIdAtTheSameAddressIsReturnedOnceAndRemembered() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("a", blocked(1))], rules: rules) == ["a"])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1)])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("a", blocked(1)), tab("a", blocked(1)), tab("a", blocked(1))], rules: rules) == [])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1)])
    }

    // The first appearance is blocked and a later one has another blocked address: the id is returned once, the FIRST address is the one remembered, the other
    // tabs around it are not disturbed, and the answer keeps the first appearance's place in the order. A last-wins decider remembers blocked(2) instead.
    @Test func aRepeatedIdWithAnotherBlockedAddressIsHandledByItsFirstAppearance() {
        var decider = TabReloadDecider()
        let result = decider.tabsToReload(processID: 1, tabs: [tab("x", blocked(7)), tab("a", blocked(1)), tab("c", blocked(5)), tab("a", blocked(2)), tab("b", blocked(3))], rules: rules)
        #expect(result == ["x", "a", "c", "b"])
        #expect(decider.remembered(processID: 1) == ["x": blocked(7), "a": blocked(1), "c": blocked(5), "b": blocked(3)])
    }

    // Three appearances with three addresses: still one id in the answer and the first address in memory.
    @Test func threeAppearancesOfOneIdAreHandledByTheFirst() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("a", blocked(2)), tab("a", blocked(3))], rules: rules) == ["a"])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1)])
    }

    // The first appearance decides against what is remembered: the memory holds blocked(2), the first appearance shows blocked(1) (a change, so the id is
    // returned and blocked(1) is remembered) even though the later appearance shows the remembered address.
    @Test func theFirstAppearanceIsComparedWithMemoryEvenWhenALaterOneEqualsIt() {
        var decider = TabReloadDecider()
        _ = decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(2))], rules: rules)
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("a", blocked(2))], rules: rules) == ["a"])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1)])
    }

    // The reverse: the first appearance equals the remembered address, so nothing happens and the memory is unchanged, although a later appearance shows a
    // different blocked address. A last-wins decider would return the id and remember blocked(2).
    @Test func aLaterAppearanceWithAnotherAddressDoesNotTriggerAReloadWhenTheFirstIsRemembered() {
        var decider = TabReloadDecider()
        _ = decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: rules)
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("a", blocked(2))], rules: rules) == [])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1)])
    }

    // The first appearance is blocked and a later one is open: the later one is ignored, so the id is returned and its blocked address stays in memory; and
    // when that address is already remembered, the memory is kept (the open appearance does not drop it).
    @Test func aLaterOpenAppearanceDoesNotDropTheFirstBlockedOne() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("a", openWatch)], rules: rules) == ["a"])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1)])
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("a", openWatch)], rules: rules) == [])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1)])
    }

    // Both appearances open: nothing is returned or remembered.
    @Test func aRepeatedIdWithOnlyOpenAddressesIsNeitherReturnedNorRemembered() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", openWatch), tab("a", newTab), tab("b", blocked(4))], rules: rules) == ["b"])
        #expect(decider.remembered(processID: 1) == ["b": blocked(4)])
    }

    // The duplicates need not be next to each other, and each id is handled by its own first appearance.
    @Test func repeatedIdsFarApartAreHandledByTheirFirstAppearances() {
        var decider = TabReloadDecider()
        let tabs = [tab("a", blocked(1)), tab("b", blocked(2)), tab("a", blocked(3)), tab("c", blocked(4)), tab("b", openHome), tab("c", blocked(5))]
        #expect(decider.tabsToReload(processID: 1, tabs: tabs, rules: rules) == ["a", "b", "c"])
        #expect(decider.remembered(processID: 1) == ["a": blocked(1), "b": blocked(2), "c": blocked(4)])
    }

    // 02 § 3c "Repeated tab id": the FIRST appearance decides. When it is open and a later one is blocked, the later one is ignored: the id is not returned and
    // nothing about it is remembered.
    @Test func aLaterBlockedAppearanceIsIgnoredWhenTheFirstAppearanceIsOpen() {
        var decider = TabReloadDecider()
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", openWatch), tab("a", blocked(1)), tab("b", blocked(2))], rules: rules) == ["b"])
        #expect(decider.remembered(processID: 1) == ["b": blocked(2)])
        var other = TabReloadDecider()
        #expect(other.tabsToReload(processID: 1, tabs: [tab("a", openWatch), tab("a", blocked(1))], rules: rules) == [])
        #expect(other.remembered(processID: 1) == [:])
    }

    // The same rule with memory: the first appearance is open, so the memory of the id is dropped; the later blocked appearance (equal to what was remembered)
    // must not bring it back, and the id is not returned.
    @Test func anOpenFirstAppearanceDropsTheMemoryEvenWhenALaterBlockedOneEqualsIt() {
        var decider = TabReloadDecider()
        _ = decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: rules)
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", openWatch), tab("a", blocked(1))], rules: rules) == [])
        #expect(decider.remembered(processID: 1) == [:])
        // Having been dropped, the tab acts again when it later shows the blocked address on its own.
        #expect(decider.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: rules) == ["a"])
    }
}

// MARK: - forgetting

@Suite struct TabReloadDeciderForgetTests {
    // Builds a decider that remembers one blocked tab ("t") for each of the given processes.
    private func decider(remembering pids: [Int32]) -> TabReloadDecider {
        var decider = TabReloadDecider()
        for pid in pids { _ = decider.tabsToReload(processID: pid, tabs: [tab("t", blocked(Int(pid)))], rules: rules) }
        return decider
    }

    // "forgetProcesses(except:) drops the memory of processes outside the set and keeps the rest."
    @Test func forgetProcessesDropsOnlyTheProcessesOutsideTheSet() {
        var d = decider(remembering: [1, 2, 3, 4])
        d.forgetProcesses(except: [2, 4])
        #expect(d.remembered(processID: 1) == [:])
        #expect(d.remembered(processID: 3) == [:])
        #expect(d.remembered(processID: 2) == ["t": blocked(2)])
        #expect(d.remembered(processID: 4) == ["t": blocked(4)])
        // The kept processes still suppress their tab; the dropped ones act again.
        #expect(d.tabsToReload(processID: 2, tabs: [tab("t", blocked(2))], rules: rules) == [])
        #expect(d.tabsToReload(processID: 4, tabs: [tab("t", blocked(4))], rules: rules) == [])
        #expect(d.tabsToReload(processID: 1, tabs: [tab("t", blocked(1))], rules: rules) == ["t"])
        #expect(d.tabsToReload(processID: 3, tabs: [tab("t", blocked(3))], rules: rules) == ["t"])
    }

    // An empty set drops every process.
    @Test func forgetProcessesWithAnEmptySetDropsEverything() {
        var d = decider(remembering: [1, 2, 3])
        d.forgetProcesses(except: [])
        for pid: Int32 in [1, 2, 3] { #expect(d.remembered(processID: pid) == [:]) }
    }

    // A set holding every remembered process drops nothing, and ids in the set that have no memory create nothing.
    @Test func forgetProcessesWithEveryRememberedProcessKeepsAllOfThem() {
        var d = decider(remembering: [1, 2, 3])
        d.forgetProcesses(except: [1, 2, 3, 99, Int32.max])
        for pid: Int32 in [1, 2, 3] { #expect(d.remembered(processID: pid) == ["t": blocked(Int(pid))]) }
        #expect(d.remembered(processID: 99) == [:])
        #expect(d.remembered(processID: Int32.max) == [:])
    }

    // A set made only of unknown ids drops all of the real ones.
    @Test func forgetProcessesWithOnlyUnknownIdsDropsEverythingRemembered() {
        var d = decider(remembering: [1, 2])
        d.forgetProcesses(except: [50, 60])
        #expect(d.remembered(processID: 1) == [:])
        #expect(d.remembered(processID: 2) == [:])
    }

    // Forgetting on a decider that remembers nothing is harmless, and forgetting twice is the same as once.
    @Test func forgettingOnAnEmptyDeciderAndForgettingTwiceAreHarmless() {
        var empty = TabReloadDecider()
        empty.forgetProcesses(except: [1])
        empty.forgetProcesses(except: [])
        empty.forgetAll()
        #expect(empty.remembered(processID: 1) == [:])
        var d = decider(remembering: [1, 2])
        d.forgetProcesses(except: [1])
        d.forgetProcesses(except: [1])
        #expect(d.remembered(processID: 1) == ["t": blocked(1)])
        #expect(d.remembered(processID: 2) == [:])
    }

    // "forgetAll() drops everything": every process, and every tab within a process.
    @Test func forgetAllDropsEverything() {
        var d = TabReloadDecider()
        _ = d.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2))], rules: rules)
        _ = d.tabsToReload(processID: 2, tabs: [tab("a", blocked(1))], rules: rules)
        d.forgetAll()
        #expect(d.remembered(processID: 1) == [:])
        #expect(d.remembered(processID: 2) == [:])
        #expect(d.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2))], rules: rules) == ["a", "b"])
        #expect(d.tabsToReload(processID: 2, tabs: [tab("a", blocked(1))], rules: rules) == ["a"])
    }

    // After forgetting, the decider works normally: it remembers again and suppresses repeats.
    @Test func theDeciderKeepsWorkingAfterForgetting() {
        var d = decider(remembering: [1])
        d.forgetAll()
        #expect(d.tabsToReload(processID: 1, tabs: [tab("t", blocked(1))], rules: rules) == ["t"])
        #expect(d.tabsToReload(processID: 1, tabs: [tab("t", blocked(1))], rules: rules) == [])
        d.forgetProcesses(except: [])
        #expect(d.tabsToReload(processID: 1, tabs: [tab("t", blocked(1))], rules: rules) == ["t"])
        #expect(d.tabsToReload(processID: 1, tabs: [tab("t", blocked(1))], rules: rules) == [])
    }
}

// MARK: - value type

@Suite struct TabReloadDeciderValueTests {
    // The decider is a value type: a copy has its own memory, and acting on one does not change the other.
    @Test func aCopyHasItsOwnMemory() {
        var original = TabReloadDecider()
        _ = original.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: rules)
        var copy = original
        #expect(copy.tabsToReload(processID: 1, tabs: [tab("a", blocked(1)), tab("b", blocked(2))], rules: rules) == ["b"])
        #expect(original.remembered(processID: 1) == ["a": blocked(1)])
        #expect(copy.remembered(processID: 1) == ["a": blocked(1), "b": blocked(2)])
        copy.forgetAll()
        #expect(original.remembered(processID: 1) == ["a": blocked(1)])
        #expect(original.tabsToReload(processID: 1, tabs: [tab("a", blocked(1))], rules: rules) == [])
    }

    // A new decider has acted on nothing: the first sight of a blocked tab always returns it.
    @Test func aNewDeciderRemembersNothing() {
        let decider = TabReloadDecider()
        for pid: Int32 in [0, 1, 4242, -5] { #expect(decider.remembered(processID: pid) == [:]) }
    }
}

// MARK: - a model of the design, compared on generated sequences

@Suite struct TabReloadDeciderModelTests {
    // The design in a few lines: per process a dictionary of tab id to the address last acted on. Written from the design text, independent of the decider.
    private struct Model {
        var memory: [Int32: [String: String]] = [:]

        // The five per-tab rules of § 3c TabReloadDecider, for a list with no repeated ids.
        mutating func tabsToReload(processID: Int32, tabs: [(id: String, url: String)], matches: (String) -> Bool, hasRules: Bool) -> [String] {
            guard hasRules else {
                memory[processID] = [:]
                return []
            }
            var updated: [String: String] = [:]
            var out: [String] = []
            for t in tabs where matches(t.url) {
                if memory[processID]?[t.id] != t.url { out.append(t.id) }
                updated[t.id] = t.url
            }
            memory[processID] = updated
            return out
        }
    }

    // Addresses with a known answer for each rule: the rule's name is the key.
    private static let pool: [(url: String, rulesMatching: Set<String>)] = [
        ("https://www.youtube.com/shorts/a", ["yt"]),
        ("https://youtube.com/shorts/b", ["yt"]),
        ("https://m.youtube.com/shorts/c?x=1", ["yt"]),
        ("https://youtube.com/shorts/aBcDeF_-12", ["yt"]),
        ("https://youtube.com/shorts/abcdef_-12", ["yt"]),
        ("https://www.youtube.com/shorts/a%20b%2Fc%E6%97%A5", ["yt"]),
        ("https://www.youtube.com/shorts/a%20b%2fc%e6%97%a5", ["yt"]),
        ("https://youtube.com/shorts/日本語", ["yt"]),
        ("https://YOUTUBE.COM/shorts/AbC", ["yt"]),
        ("https://example.com/shorts/ZzZ", ["ex"]),
        ("https://example.com/shorts/zzz", ["ex"]),
        ("https://youtube.com/Shorts/abc", []),
        ("https://example.com/shorts/z", ["ex"]),
        ("https://www.example.com/shorts", ["ex"]),
        ("https://youtube.com/watch?v=1", []),
        ("https://example.com/", []),
        ("chrome://newtab/", []),
        ("https://youtube.com/short", []),
    ]
    private static let ruleSets: [(names: Set<String>, rules: [WatchedPathRule])] = [
        ([], []),
        (["yt"], [WatchedPathRule(domain: "youtube.com", path: "/shorts")]),
        (["ex"], [WatchedPathRule(domain: "example.com", path: "/shorts")]),
        (["yt", "ex"], [WatchedPathRule(domain: "youtube.com", path: "/shorts"), WatchedPathRule(domain: "example.com", path: "/shorts")]),
        (["ex", "yt"], [WatchedPathRule(domain: "example.com", path: "/shorts"), WatchedPathRule(domain: "youtube.com", path: "/shorts")]),
    ]

    // Random sequences of calls, rule changes, process forgetting and full forgetting; after every step the decider's answer and its memory for every process
    // must equal the model's.
    @Test(arguments: [1, 2, 3, 4, 5, 6])
    func theDeciderFollowsTheDesignOnGeneratedSequences(seed: Int) {
        var generator = DeciderGenerator(state: UInt64(seed) &* 0x1234_5678_9ABC_DEF1)
        var decider = TabReloadDecider()
        var model = Model()
        let pids: [Int32] = [1, 2, 3, 4]
        let ids = ["a", "b", "c", "d", "e", "f"]
        // The last list sent for each process: reusing it (sometimes with one address changed) is what makes repeats, and so suppression, common.
        var lastTabs: [Int32: [(id: String, url: String)]] = [:]
        var returnedTotal = 0
        var suppressedTotal = 0
        var forgottenOps = 0
        var emptyRuleCalls = 0
        for step in 0..<400 {
            let roll = Int.random(in: 0..<100, using: &generator)
            if roll < 8 {
                let keep = Set(pids.filter { _ in Bool.random(using: &generator) })
                decider.forgetProcesses(except: keep)
                model.memory = model.memory.filter { keep.contains($0.key) }
                forgottenOps += 1
            } else if roll < 12 {
                decider.forgetAll()
                model.memory = [:]
                forgottenOps += 1
            } else {
                let pid = pids[Int.random(in: 0..<pids.count, using: &generator)]
                let set = Self.ruleSets[Int.random(in: 0..<Self.ruleSets.count, using: &generator)]
                var tabs: [(id: String, url: String)]
                let reuse = Int.random(in: 0..<100, using: &generator)
                if reuse < 55, let previous = lastTabs[pid] {
                    tabs = previous
                    if reuse < 15, !tabs.isEmpty {
                        let at = Int.random(in: 0..<tabs.count, using: &generator)
                        tabs[at] = tab(tabs[at].id, Self.pool[Int.random(in: 0..<Self.pool.count, using: &generator)].url)
                    }
                } else {
                    let tabIds = Array(ids.shuffled(using: &generator).prefix(Int.random(in: 0...ids.count, using: &generator)))
                    tabs = tabIds.map { tab($0, Self.pool[Int.random(in: 0..<Self.pool.count, using: &generator)].url) }
                }
                lastTabs[pid] = tabs
                let matching: (String) -> Bool = { url in
                    guard let entry = Self.pool.first(where: { $0.url == url }) else { return false }
                    return !entry.rulesMatching.isDisjoint(with: set.names)
                }
                let before = model.memory[pid] ?? [:]
                let expected = model.tabsToReload(processID: pid, tabs: tabs, matches: matching, hasRules: !set.rules.isEmpty)
                let actual = decider.tabsToReload(processID: pid, tabs: tabs, rules: set.rules)
                #expect(actual == expected, "seed \(seed) step \(step): process \(pid) tabs \(tabs.map { "\($0.id)=\($0.url)" }) rules \(set.names)")
                returnedTotal += actual.count
                suppressedTotal += tabs.filter { matching($0.url) && before[$0.id] == $0.url }.count
                if set.rules.isEmpty { emptyRuleCalls += 1 }
            }
            for pid in pids {
                #expect(decider.remembered(processID: pid) == (model.memory[pid] ?? [:]), "seed \(seed) step \(step): memory of process \(pid)")
            }
        }
        // Guards against a generator that drifts into doing nothing: tabs were acted on, repeats were suppressed, memory was cleared on purpose.
        #expect(returnedTotal > 100, "seed \(seed): only \(returnedTotal) tabs were returned")
        #expect(suppressedTotal > 20, "seed \(seed): only \(suppressedTotal) repeats were suppressed")
        #expect(forgottenOps > 10, "seed \(seed): only \(forgottenOps) forgetting operations ran")
        #expect(emptyRuleCalls > 10, "seed \(seed): only \(emptyRuleCalls) calls had no rules")
    }
}
