import AppKit
import CoreServices
import Foundation

// This file talks to Chrome, Edge, Brave and Safari with Apple Events (the macOS way for one app to ask another app for data or to make it do something; AppleScript uses the same thing). It depends only on Foundation, AppKit and CoreServices and on no other file of the app, so a test harness can compile it on its own with swiftc.

/// What macOS says about whether SiteBlock may send Apple Events to one running browser.
enum AutomationPermission: Equatable {
    /// The person allowed it.
    case allowed
    /// The person refused it, or turned it off later in System Settings.
    case denied
    /// The person has not been asked yet, and this check was not allowed to ask.
    case notAsked
    /// macOS could not answer, for example because the browser is not running (any answer other than the three above).
    case unavailable
}

/// Why an Apple Event to a browser did not give a usable answer.
enum BrowserTabsError: Error, Equatable {
    /// The event could not be delivered, the browser answered with an error, or it did not answer in time. The number is the macOS error number, for example -1743 (not allowed), -1712 (timed out) or -1728 (no such window or tab).
    case appleEvent(code: Int, message: String)
    /// The browser answered, but not in the shape expected.
    case unexpectedReply(String)

    /// The macOS error number, or nil for an answer in an unexpected shape.
    var code: Int? {
        if case .appleEvent(let code, _) = self { return code }
        return nil
    }
}

/// Which scripting dictionary (the list of objects and commands an app offers to Apple Events) a browser uses. It decides the codes for tabs and addresses, and how one tab is named in an event.
enum BrowserKind: Equatable {
    /// Chrome, Edge and Brave. Each tab has an id that stays the same while the tab is open.
    case chromium
    /// Safari. A tab has no id, only its position in its window counted from 1 on the left, which changes when a tab before it opens or closes.
    case safari
}

/// One running process of a supported browser.
struct RunningBrowser: Equatable {
    /// The process id, which every event is addressed to.
    let pid: pid_t
    /// The app's bundle identifier, for example com.google.Chrome.
    let bundleID: String
    /// The name shown to people, for example Google Chrome.
    let name: String
    /// Which scripting dictionary it uses.
    let kind: BrowserKind
}

/// One open tab as `BrowserTabs.readTabs` reports it.
struct BrowserTab: Equatable {
    /// The id of the window the tab is in.
    let windowID: String
    /// The tab's id in a Chromium browser, or its position in its window ("1", "2", ...) in Safari.
    let tabID: String
    /// The tab's address, or empty when the browser gave none.
    let url: String

    /// The window id and tab id joined, which names the tab among all tabs of its browser process. The tab id alone is not enough, because a Safari position is unique only inside one window.
    var key: String { "\(windowID)/\(tabID)" }
}

/// Reads the open tabs of the supported browsers and sends single tabs to a new address. Every function addresses one browser process by its process id, because a person can run more than one Chrome at once (for example a second one started with its own `--user-data-dir` is a separate process) and an Apple Event sent by app name reaches only one of them.
enum BrowserTabs {
    /// The supported browsers: bundle identifier (the app's unique name) to the name shown to people and the scripting dictionary it uses.
    static let supportedBrowsers: [String: (name: String, kind: BrowserKind)] = [
        "com.google.Chrome": ("Google Chrome", .chromium),
        "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
        "com.brave.Browser": ("Brave", .chromium),
        "com.apple.Safari": ("Safari", .safari),
    ]

    /// How long to wait for a browser to answer one event, in seconds.
    private static let eventTimeoutSeconds: TimeInterval = 2

    // Window codes are the standard ones both dictionaries share. Tab and address codes come from /Applications/Google Chrome.app/Contents/Resources/scripting.sdef and /Applications/Safari.app/Contents/Resources/Safari.sdef.
    /// The window class (`cwin`).
    private static let windowClass = fourCharCode("cwin")
    /// The `id` property (`ID  `, with two trailing spaces). It is also the form code for "the item with this id".
    private static let idProperty = fourCharCode("ID  ")

    /// The tab class: `CrTb` in Chromium browsers, `bTab` in Safari.
    private static func tabClass(_ kind: BrowserKind) -> FourCharCode {
        kind == .chromium ? fourCharCode("CrTb") : fourCharCode("bTab")
    }

    /// The tab's `URL` property: `URL ` (with a trailing space) in Chromium browsers, `pURL` in Safari.
    private static func urlProperty(_ kind: BrowserKind) -> FourCharCode {
        kind == .chromium ? fourCharCode("URL ") : fourCharCode("pURL")
    }

    // MARK: - Browsers and permission

    /// The supported browsers that are running right now, one entry per process, skipping any that are quitting.
    static func runningBrowsers() -> [RunningBrowser] {
        var found: [RunningBrowser] = []
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let bundleID = app.bundleIdentifier, let known = supportedBrowsers[bundleID] else { continue }
            found.append(RunningBrowser(pid: app.processIdentifier, bundleID: bundleID, name: known.name, kind: known.kind))
        }
        return found.sorted { $0.pid < $1.pid }
    }

    /// Asks macOS whether SiteBlock may control the browser process. With `ask` true and no earlier answer, macOS shows its prompt ("SiteBlock wants access to control ...") and this call waits until the person answers, so it must never run on the main thread. With `ask` false it never shows anything.
    static func permission(pid: pid_t, ask: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let targetDescriptor = target.aeDesc else { return .unavailable }
        let status = AEDeterminePermissionToAutomateTarget(targetDescriptor, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case OSStatus(noErr): return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        // Anything else, for example procNotFound (-600) because the browser quit, means there is no answer to give.
        default: return .unavailable
        }
    }

    // MARK: - Reading tabs

    /// Lists every tab of every window of the browser process: the window id, the tab's id and the tab's address. In Chromium browsers a window's tabs are used only when its tab ids, read before and after the addresses, are the same list and as long as the address list, which proves the ids and addresses line up; a tab opened, closed or moved in between makes that window be skipped this time. In Safari all addresses of a window come back in one answer, in tab order, so each tab's id is its position in that list ("1", "2", ...). A window that disappears while being read, or that has no tabs to read (Safari keeps hidden windows such as its sign-in sheet), is skipped. Any other failure (a timeout, a quit browser, revoked permission) is thrown.
    static func readTabs(_ browser: RunningBrowser) throws -> [BrowserTab] {
        var tabs: [BrowserTab] = []
        let windowIDs = try ids(pid: browser.pid, of: property(idProperty, of: every(windowClass, in: nullContainer())))
        for windowID in windowIDs {
            do {
                let allTabs = try every(tabClass(browser.kind), in: windowSpecifier(windowID))
                let urlsOfAllTabs = try property(urlProperty(browser.kind), of: allTabs)
                switch browser.kind {
                case .chromium:
                    // The ids are read on both sides of the addresses. If the tab list changed in between, ids and addresses may be paired wrongly, so none of this window's tabs are used.
                    let idsBefore = try ids(pid: browser.pid, of: property(idProperty, of: allTabs))
                    let urls = try strings(pid: browser.pid, of: urlsOfAllTabs)
                    let idsAfter = try ids(pid: browser.pid, of: property(idProperty, of: allTabs))
                    guard idsBefore == idsAfter, urls.count == idsBefore.count else { continue }
                    for (tabID, url) in zip(idsBefore, urls) { tabs.append(BrowserTab(windowID: windowID, tabID: tabID, url: url)) }
                case .safari:
                    let urls = try strings(pid: browser.pid, of: urlsOfAllTabs)
                    for (offset, url) in urls.enumerated() { tabs.append(BrowserTab(windowID: windowID, tabID: String(offset + 1), url: url)) }
                }
            } catch let error as BrowserTabsError where error.code == Int(errAENoSuchObject) || error.code == Int(errAEIllegalIndex) {
                // The window closed between the two requests, or it holds no tabs; the others are still worth reading.
                continue
            }
        }
        return tabs
    }

    /// Reads the address of one tab, found by its window id and tab id.
    static func currentURL(_ browser: RunningBrowser, windowID: String, tabID: String) throws -> String {
        let tab = try tabSpecifier(browser.kind, windowID: windowID, tabID: tabID)
        let strings = try strings(pid: browser.pid, of: property(urlProperty(browser.kind), of: tab))
        guard let url = strings.first, strings.count == 1 else { throw BrowserTabsError.unexpectedReply("the address of one tab did not come back as one text") }
        return url
    }

    /// Sends a tab to a new address by setting its `URL` property, which is what AppleScript's `set URL of tab ... to ...` does; the browser loads the new address in that tab as if it had been typed. In a Chromium browser the tab is the one with that window id and tab id. In Safari a position is not safe to act on, because a tab opening or closing between the caller's read and this event moves another tab into it, so the event instead names every tab of that window whose address is exactly `currentURL`, and Safari picks them out itself when the event arrives. Every such tab is on the same blocked address, and when none is left (the tab moved on), nothing changes.
    static func open(_ url: String, in browser: RunningBrowser, windowID: String, tabID: String, currentURL: String) throws {
        let tabs: NSAppleEventDescriptor
        switch browser.kind {
        case .chromium: tabs = try tabSpecifier(browser.kind, windowID: windowID, tabID: tabID)
        case .safari: tabs = try tabsWhoseURL(is: currentURL, kind: browser.kind, windowID: windowID)
        }
        let event = makeEvent(pid: browser.pid, eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAESetData))
        event.setParam(try property(urlProperty(browser.kind), of: tabs), forKeyword: AEKeyword(keyDirectObject))
        event.setParam(NSAppleEventDescriptor(string: url), forKeyword: AEKeyword(keyAEData))
        _ = try send(event)
    }

    // MARK: - Asking for values

    /// Sends `get` for the specifier and returns the items of the answer. A list answer gives its items; a single value gives one item; an empty answer gives none.
    private static func get(pid: pid_t, _ specifier: NSAppleEventDescriptor) throws -> [NSAppleEventDescriptor] {
        let event = makeEvent(pid: pid, eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData))
        event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        let reply = try send(event)
        guard let answer = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return [] }
        if answer.descriptorType == DescType(typeAEList) {
            return stride(from: 1, through: answer.numberOfItems, by: 1).compactMap { answer.atIndex($0) }
        }
        // A "missing value" answer holds nothing.
        if answer.descriptorType == DescType(typeNull) { return [] }
        return [answer]
    }

    /// Gets a property such as `id` and returns each value as text. Browsers send ids as integers, and the text form of an integer is its digits.
    private static func ids(pid: pid_t, of specifier: NSAppleEventDescriptor) throws -> [String] {
        try get(pid: pid, specifier).map { item in
            guard let text = item.stringValue else { throw BrowserTabsError.unexpectedReply("an id did not come back as a number or text") }
            return text
        }
    }

    /// Gets a property such as `URL` and returns each value as text. A value that is not text, such as a missing value for a tab that is still opening or an empty Safari tab, counts as an empty address, which matches no rule.
    private static func strings(pid: pid_t, of specifier: NSAppleEventDescriptor) throws -> [String] {
        try get(pid: pid, specifier).map { $0.stringValue ?? "" }
    }

    // MARK: - Sending events

    /// Creates an Apple Event addressed to one process by its process id.
    private static func makeEvent(pid: pid_t, eventClass: AEEventClass, eventID: AEEventID) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        return NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID, targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// Sends the event, waits up to two seconds for the answer, and returns it. Delivery failures and errors the browser reports in its answer are both thrown as `BrowserTabsError.appleEvent`.
    private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply], timeout: eventTimeoutSeconds)
        } catch {
            throw BrowserTabsError.appleEvent(code: (error as NSError).code, message: error.localizedDescription)
        }
        // A browser that cannot do what was asked still delivers a reply; the failure is in its error-number field.
        if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, number != 0 {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? ""
            throw BrowserTabsError.appleEvent(code: Int(number), message: message)
        }
        return reply
    }

    // MARK: - Object specifiers

    /// The container for things that sit directly in the application, such as its windows.
    private static func nullContainer() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.null()
    }

    /// Builds an object specifier: "the item of class `want` inside `container`, chosen with `form` and `data`". It is a record of type `obj ` with the keys `want`, `from`, `form` and `seld`.
    private static func specifier(want: DescType, in container: NSAppleEventDescriptor, form: DescType, data: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        guard let record = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw BrowserTabsError.unexpectedReply("an object specifier could not be built") }
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        return record
    }

    /// "Every item of class `want` in `container`", for example every window or every tab of a window. The form is absolute position and the position is the "all" code.
    private static func every(_ want: DescType, in container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        var all = UInt32(kAEAll)
        guard let position = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal), bytes: &all, length: MemoryLayout<UInt32>.size) else { throw BrowserTabsError.unexpectedReply("an 'every' position could not be built") }
        return try specifier(want: want, in: container, form: DescType(formAbsolutePosition), data: position)
    }

    /// "The item of class `want` in `container` whose id is `id`".
    private static func item(_ want: DescType, withID id: String, in container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(want: want, in: container, form: DescType(formUniqueID), data: idDescriptor(id))
    }

    /// "Property `code` of `container`", for example the `id` of every window or the `URL` of one tab.
    private static func property(_ code: DescType, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(want: DescType(cProperty), in: container, form: DescType(formPropertyID), data: NSAppleEventDescriptor(typeCode: code))
    }

    /// "Window id W".
    private static func windowSpecifier(_ windowID: String) throws -> NSAppleEventDescriptor {
        try item(windowClass, withID: windowID, in: nullContainer())
    }

    /// One tab of window id W: "tab id T" in a Chromium browser, or "tab T" (the tab at position T) in Safari. A Safari tab id that is not a positive number cannot name a tab, so it is refused here rather than sent.
    private static func tabSpecifier(_ kind: BrowserKind, windowID: String, tabID: String) throws -> NSAppleEventDescriptor {
        let window = try windowSpecifier(windowID)
        switch kind {
        case .chromium:
            return try item(tabClass(kind), withID: tabID, in: window)
        case .safari:
            guard let position = Int32(tabID), position > 0 else { throw BrowserTabsError.unexpectedReply("a Safari tab position was not a positive number") }
            return try specifier(want: tabClass(kind), in: window, form: DescType(formAbsolutePosition), data: NSAppleEventDescriptor(int32: position))
        }
    }

    /// "Every tab of window id W whose URL is `url`": an object specifier with the test form, whose test compares the `URL` property of the tab being examined with the text for equality. The browser evaluates the test itself when the event arrives.
    private static func tabsWhoseURL(is url: String, kind: BrowserKind, windowID: String) throws -> NSAppleEventDescriptor {
        guard let examined = NSAppleEventDescriptor(descriptorType: DescType(typeObjectBeingExamined), data: nil), let comparison = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeCompDescriptor)) else { throw BrowserTabsError.unexpectedReply("a 'whose' test could not be built") }
        comparison.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(kAEEquals)), forKeyword: AEKeyword(keyAECompOperator))
        comparison.setDescriptor(try property(urlProperty(kind), of: examined), forKeyword: AEKeyword(keyAEObject1))
        comparison.setDescriptor(NSAppleEventDescriptor(string: url), forKeyword: AEKeyword(keyAEObject2))
        return try specifier(want: tabClass(kind), in: windowSpecifier(windowID), form: DescType(formTest), data: comparison)
    }

    /// The descriptor that carries an id inside a specifier. An id made of digits goes back as a 32-bit integer, which is the type browsers send ids as and the only type Chromium browsers accept them in; any other text goes back as text.
    private static func idDescriptor(_ id: String) -> NSAppleEventDescriptor {
        if let number = Int32(id) { return NSAppleEventDescriptor(int32: number) }
        return NSAppleEventDescriptor(string: id)
    }

    /// Turns a four-character code such as "cwin" into the number macOS uses for it.
    private static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
    }
}
