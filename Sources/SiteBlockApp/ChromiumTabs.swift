import AppKit
import CoreServices
import Foundation

// This file talks to Chrome, Edge and Brave with Apple Events (the macOS way for one app to ask another app for data or to make it do something; AppleScript uses the same thing). It depends only on Foundation, AppKit and CoreServices and on no other file of the app, so a test harness can compile it on its own with swiftc.

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
enum ChromiumTabsError: Error, Equatable {
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

/// Reads the open tabs of Chromium-based browsers and reloads single tabs. Every function addresses one browser process by its process id, because a person can run more than one Chrome at once (for example a second one started with its own `--user-data-dir` is a separate process) and an Apple Event sent by app name reaches only one of them.
enum ChromiumTabs {
    /// The supported browsers: bundle identifier (the app's unique name) to the name shown to people. All three use Chromium's scripting dictionary, so the codes below are the same for each.
    static let supportedBrowsers: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave",
    ]

    /// How long to wait for a browser to answer one event, in seconds.
    private static let eventTimeoutSeconds: TimeInterval = 2

    // Codes from /Applications/Google Chrome.app/Contents/Resources/scripting.sdef.
    /// The window class (`cwin`).
    private static let windowClass = fourCharCode("cwin")
    /// The tab class (`CrTb`).
    private static let tabClass = fourCharCode("CrTb")
    /// The `id` property (`ID  `, with two trailing spaces). It is also the form code for "the item with this id".
    private static let idProperty = fourCharCode("ID  ")
    /// The `URL` property (`URL `, with a trailing space).
    private static let urlProperty = fourCharCode("URL ")
    /// The event class of Chromium's own commands (`CrSu`).
    private static let chromiumSuite = fourCharCode("CrSu")
    /// The `reload` command's event id (`Rlod`).
    private static let reloadEvent = fourCharCode("Rlod")

    // MARK: - Browsers and permission

    /// The supported browsers that are running right now, one entry per process, skipping any that are quitting.
    static func runningBrowsers() -> [(pid: pid_t, bundleID: String, name: String)] {
        var found: [(pid: pid_t, bundleID: String, name: String)] = []
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let bundleID = app.bundleIdentifier, let name = supportedBrowsers[bundleID] else { continue }
            found.append((pid: app.processIdentifier, bundleID: bundleID, name: name))
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

    /// Lists every tab of every window of the browser process: the window id, the tab id and the tab's address. A window's tabs are used only when its tab ids, read before and after the addresses, are the same list and as long as the address list, which proves the ids and addresses line up; a tab opened, closed or moved in between makes that window be skipped this time. A window that disappears while being read is skipped too. Any other failure (a timeout, a quit browser, revoked permission) is thrown.
    static func readTabs(pid: pid_t) throws -> [(windowID: String, tabID: String, url: String)] {
        var tabs: [(windowID: String, tabID: String, url: String)] = []
        let windowIDs = try ids(pid: pid, of: property(idProperty, of: every(windowClass, in: nullContainer())))
        for windowID in windowIDs {
            do {
                let window = try windowSpecifier(windowID)
                let allTabs = try every(tabClass, in: window)
                let idsBefore = try ids(pid: pid, of: property(idProperty, of: allTabs))
                let urls = try strings(pid: pid, of: property(urlProperty, of: allTabs))
                let idsAfter = try ids(pid: pid, of: property(idProperty, of: allTabs))
                // If the tab list changed while it was being read, ids and addresses may be paired wrongly, so none of this window's tabs are used.
                guard idsBefore == idsAfter, urls.count == idsBefore.count else { continue }
                for (tabID, url) in zip(idsBefore, urls) { tabs.append((windowID: windowID, tabID: tabID, url: url)) }
            } catch let error as ChromiumTabsError where error.code == Int(errAENoSuchObject) {
                // The window closed between the two requests; the others are still worth reading.
                continue
            }
        }
        return tabs
    }

    /// Reads the address of one tab, found by its window id and tab id.
    static func currentURL(pid: pid_t, windowID: String, tabID: String) throws -> String {
        let tab = try tabSpecifier(windowID: windowID, tabID: tabID)
        let strings = try strings(pid: pid, of: property(urlProperty, of: tab))
        guard let url = strings.first, strings.count == 1 else { throw ChromiumTabsError.unexpectedReply("the address of one tab did not come back as one text") }
        return url
    }

    /// Reloads one tab, found by its window id and tab id. A reload is a real page load, so the browser's own block list is applied to the address.
    static func reload(pid: pid_t, windowID: String, tabID: String) throws {
        let tab = try tabSpecifier(windowID: windowID, tabID: tabID)
        let event = makeEvent(pid: pid, eventClass: chromiumSuite, eventID: reloadEvent)
        event.setParam(tab, forKeyword: AEKeyword(keyDirectObject))
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
            guard let text = item.stringValue else { throw ChromiumTabsError.unexpectedReply("an id did not come back as a number or text") }
            return text
        }
    }

    /// Gets a property such as `URL` and returns each value as text. A value that is not text, such as a missing value for a tab that is still opening, counts as an empty address, which matches no rule.
    private static func strings(pid: pid_t, of specifier: NSAppleEventDescriptor) throws -> [String] {
        try get(pid: pid, specifier).map { $0.stringValue ?? "" }
    }

    // MARK: - Sending events

    /// Creates an Apple Event addressed to one process by its process id.
    private static func makeEvent(pid: pid_t, eventClass: AEEventClass, eventID: AEEventID) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        return NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID, targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// Sends the event, waits up to two seconds for the answer, and returns it. Delivery failures and errors the browser reports in its answer are both thrown as `ChromiumTabsError.appleEvent`.
    private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply], timeout: eventTimeoutSeconds)
        } catch {
            throw ChromiumTabsError.appleEvent(code: (error as NSError).code, message: error.localizedDescription)
        }
        // A browser that cannot do what was asked still delivers a reply; the failure is in its error-number field.
        if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, number != 0 {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? ""
            throw ChromiumTabsError.appleEvent(code: Int(number), message: message)
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
        guard let record = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw ChromiumTabsError.unexpectedReply("an object specifier could not be built") }
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        return record
    }

    /// "Every item of class `want` in `container`", for example every window or every tab of a window. The form is absolute position and the position is the "all" code.
    private static func every(_ want: DescType, in container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        var all = UInt32(kAEAll)
        guard let position = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal), bytes: &all, length: MemoryLayout<UInt32>.size) else { throw ChromiumTabsError.unexpectedReply("an 'every' position could not be built") }
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

    /// "Tab id T of window id W".
    private static func tabSpecifier(windowID: String, tabID: String) throws -> NSAppleEventDescriptor {
        try item(tabClass, withID: tabID, in: windowSpecifier(windowID))
    }

    /// The descriptor that carries an id inside a specifier. An id made of digits goes back as a 32-bit integer, which is the type Chromium browsers send ids as and the only type they accept them in; any other text goes back as text.
    private static func idDescriptor(_ id: String) -> NSAppleEventDescriptor {
        if let number = Int32(id) { return NSAppleEventDescriptor(int32: number) }
        return NSAppleEventDescriptor(string: id)
    }

    /// Turns a four-character code such as "cwin" into the number macOS uses for it.
    private static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
    }
}
