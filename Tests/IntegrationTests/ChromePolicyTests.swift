import Foundation
import SiteBlockCore
import Testing

// Chrome's mandatory URLBlocklist policy, written by the real siteblockd running in sandbox mode.
// Design: 03-daemon-cli-app.md § 9 ChromePolicyEnforcer (files written, content rules, writing, tamper repair and logging, uninstall);
// 04-infrastructure.md § Installed Paths and § Sandbox Mode (the sandbox copies live under root/ManagedPreferences/);
// 01-overview-and-data.md § How Blocking Works (Chrome paragraph: the list is every host of every blocked site, so it differs from the
// hosts file only by the iCloud Private Relay names, which Chrome has no use for).
//
// The two files are root/ManagedPreferences/com.google.Chrome.plist and root/ManagedPreferences/<console user>/com.google.Chrome.plist.
// The console user is the owner of /dev/console; when that is root only the machine-wide copy is written. Every expected list below is
// built by ExpectedHosts from the design's expansion rules, never read back from the daemon.

private let policyFileName = "com.google.Chrome.plist"
private let blocklistKey = "URLBlocklist"
private let repairedLine = "Chrome policy repaired"

// Which of the two policy files a test looks at.
enum ChromePolicyFile: CaseIterable, CustomTestStringConvertible {
    case machine, user

    var testDescription: String { self == .machine ? "machine-wide file" : "per-user file" }
}

// The ways a test damages a policy file that already holds the right list.
enum ChromeTamper: CaseIterable, CustomTestStringConvertible {
    case notAPlistAtAll, emptyFile, binaryBytes, truncatedXML, arrayRoot

    var testDescription: String { "\(self)" }

    // The bytes the damaged file is overwritten with (in place, as a careless editor would).
    var bytes: Data {
        switch self {
        case .notAPlistAtAll: return Data("this is not a property list at all\n".utf8)
        case .emptyFile: return Data()
        case .binaryBytes: return Data([0xFF, 0xFE, 0x00, 0x01, 0x80, 0x00, 0xC3, 0x28])
        case .truncatedXML: return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n<key>URLBlocklist</key>\n<array>\n<string>youtu".utf8)
        // A valid property list whose top level is an array: Chrome reads a dictionary, so this is as good as garbage.
        case .arrayRoot: return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><array><string>youtube.com</string></array></plist>\n".utf8)
        }
    }
}

// The ways a test changes the list inside an otherwise valid file.
enum ChromeListEdit: CaseIterable, CustomTestStringConvertible {
    case emptied, keyRemoved, extraEntryAdded, wrongType

    var testDescription: String { "\(self)" }

    // Applies the edit to a file's dictionary.
    func apply(to plist: inout [String: Any]) {
        switch self {
        case .emptied: plist[blocklistKey] = [String]()
        case .keyRemoved: plist[blocklistKey] = nil
        case .extraEntryAdded: plist[blocklistKey] = ((plist[blocklistKey] as? [String]) ?? []) + ["extra.example"]
        case .wrongType: plist[blocklistKey] = "youtube.com"
        }
    }
}

// Where one sandbox daemon is expected to write its policy files.
struct ChromePolicyPaths {
    // The sandbox's ManagedPreferences folder.
    let directory: String
    // The console user's name, or nil when root owns /dev/console (nobody is logged in), in which case the design writes only the machine-wide copy.
    let consoleUser: String?

    var machine: String { directory + "/" + policyFileName }
    var userDirectory: String? { consoleUser.map { directory + "/" + $0 } }
    var user: String? { userDirectory.map { $0 + "/" + policyFileName } }

    // The files the daemon is expected to write: the machine-wide copy, and the per-user copy when there is a console user.
    var all: [String] { [machine] + (user.map { [$0] } ?? []) }

    // The path of one file, or nil for the per-user file when it is not written.
    func path(_ file: ChromePolicyFile) -> String? { file == .machine ? machine : user }
}

// Helpers that read and edit the policy files the way Chrome and an administrator would.
private extension SandboxDaemon {
    // Works out the two policy paths from the sandbox folder and the owner of /dev/console. Throws when /dev/console cannot be inspected.
    func chromePaths() throws -> ChromePolicyPaths {
        let attributes = try FileManager.default.attributesOfItem(atPath: "/dev/console")
        guard let uid = (attributes[.ownerAccountID] as? NSNumber)?.intValue, let name = attributes[.ownerAccountName] as? String, !name.isEmpty else {
            throw TestFailure("could not read the owner of /dev/console")
        }
        return ChromePolicyPaths(directory: root + "/ManagedPreferences", consoleUser: uid == 0 ? nil : name)
    }
}

// True when something (a file, folder or link, even a dangling one) exists at the path.
private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

// The top-level dictionary of a property list file, or nil when the file is missing, is not a property list, or is not a dictionary.
private func readPlist(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
}

// The storage format of a property list file (xml1 or binary1), or nil when it cannot be parsed.
private func plistFormat(_ path: String) -> PropertyListSerialization.PropertyListFormat? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    var format = PropertyListSerialization.PropertyListFormat.binary
    guard (try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)) != nil else { return nil }
    return format
}

// The URLBlocklist strings in a policy file, or nil when the file or the key is missing or the value is not an array of strings.
private func listed(_ path: String) -> [String]? {
    readPlist(path)?[blocklistKey] as? [String]
}

// Writes a dictionary as an XML property list through a rename, so the daemon can never read a half-written file.
private func writePlist(_ plist: [String: Any], to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

// Reads a file's dictionary (empty when missing), lets the change edit it, and writes it back.
private func editPlist(at path: String, _ change: (inout [String: Any]) -> Void) throws {
    var plist = readPlist(path) ?? [:]
    change(&plist)
    try writePlist(plist, to: path)
}

// True when the dictionary has exactly the given keys with equal values.
private func isExactly(_ plist: [String: Any]?, _ expected: [String: Any]) -> Bool {
    guard let plist else { return false }
    return NSDictionary(dictionary: plist).isEqual(to: expected)
}

// True when the file holds exactly {URLBlocklist: list} and has the mode 0644 the design gives the files.
private func isRight(_ path: String, list: [String]) -> Bool {
    isExactly(readPlist(path), [blocklistKey: list]) && permissions(of: path) == 0o644
}

// The relative paths of every regular file under a folder (empty when the folder does not exist), sorted. Hidden files are included, so a leftover temp file with a dotted name is seen.
private func regularFiles(under directory: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
    var found: [String] = []
    for case let relative as String in walker {
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory + "/" + relative)
        if (attributes?[.type] as? FileAttributeType) != .typeDirectory { found.append(relative) }
    }
    return found.sorted()
}

@Suite("Chrome policy files")
struct ChromePolicyTests {
    static let youtube = ExpectedHosts.expand("youtube.com")
    static let password = SandboxDaemon.password

    // MARK: writing on a command

    // 03 § ChromePolicyEnforcer "Files written" and "Content rules": after "add youtube.com" both files hold URLBlocklist equal to exactly the expanded YouTube hosts (the list of every host of the site, sorted, without the Private Relay names the hosts file also gets). The daemon here has a 60 s tick, so only the pass that follows the command can have written them; they are read the moment the reply arrives (03 § DaemonRuntime "After every command": a newly added site is blocked before the response is sent). The file must be an XML property list with nothing but the one key, mode 0644, in folders of mode 0755.
    @Test func addingASiteWritesBothPolicyFilesBeforeTheResponseReturns() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            let chrome = try daemon.chromePaths()
            try daemon.setUp()
            #expect(chrome.all.allSatisfy { !exists($0) }, "nothing is blocked yet, so no policy file may exist")
            try daemon.send(.add, domain: "youtube.com").requireOK()
            let expected = Self.youtube
            for path in chrome.all {
                #expect(listed(path) == expected, "\(path) holds \(String(describing: listed(path)))")
                #expect(isExactly(readPlist(path), [blocklistKey: expected]), "\(path) must hold nothing but URLBlocklist")
                #expect(plistFormat(path) == .xml, "\(path) must be an XML property list")
                #expect(permissions(of: path) == 0o644, "\(path) must be mode 0644")
                #expect(!(listed(path) ?? []).contains(where: { ExpectedHosts.privateRelayHosts.contains($0) }), "the Private Relay names belong in the hosts file only")
            }
            #expect(permissions(of: chrome.directory) == 0o755, "the ManagedPreferences folder must be mode 0755")
            if let userDirectory = chrome.userDirectory { #expect(permissions(of: userDirectory) == 0o755, "the per-user folder must be mode 0755") }
            // The hosts file does hold the Private Relay names, so the difference between the two lists is real and not an empty comparison.
            #expect(daemon.hosts().blocks("mask.icloud.com"))
            // When nobody is logged in only the machine-wide copy exists; otherwise the folder holds the machine file and one folder named after the console user.
            let expectedEntries = ([policyFileName] + (chrome.consoleUser.map { [$0] } ?? [])).sorted()
            #expect(daemon.listing(of: chrome.directory).sorted() == expectedEntries)
        }
    }

    // Each add rewrites both files with every site blocked so far, and the rewrites leave nothing behind: no temp files in either folder after several adds and a repair.
    @Test func severalAddsGrowTheListAndLeaveNoTempFilesBehind() throws {
        try withDaemon { daemon in
            let chrome = try daemon.chromePaths()
            try daemon.setUp()
            var blocked: [String] = []
            for domain in ["youtube.com", "reddit.com", "x.com"] {
                try daemon.block(domain)
                blocked.append(domain)
                let expected = ExpectedHosts.expand(all: blocked)
                for path in chrome.all { #expect(listed(path) == expected, "after adding \(domain), \(path) holds \(String(describing: listed(path)))") }
            }
            // One repair on top, so the temp-file path of a pass not caused by a command is covered too.
            for path in chrome.all { try ChromeTamper.notAPlistAtAll.bytes.write(to: URL(fileURLWithPath: path)) }
            let expected = ExpectedHosts.expand(all: blocked)
            let repaired = waitUntil(timeout: 1.5, interval: 0.01) { chrome.all.allSatisfy { isRight($0, list: expected) } }
            #expect(repaired != nil)
            pause(0.6)
            let relative = chrome.all.map { String($0.dropFirst(chrome.directory.count + 1)) }.sorted()
            #expect(regularFiles(under: chrome.directory) == relative, "only the policy files may exist, found \(regularFiles(under: chrome.directory))")
        }
    }

    // MARK: tamper repair

    // 03 § ChromePolicyEnforcer "Tamper repair and logging": a deleted file comes back within one second (the sandbox tick is 0.2 s), and the pass that rewrote it, which no command caused, logs "Chrome policy repaired". The log must NOT hold that line before the tampering, because the writes caused by the commands are not repairs: without that check a daemon that logged on every write would pass.
    @Test(arguments: ChromePolicyFile.allCases)
    func aDeletedPolicyFileComesBackWithinOneSecondAndIsLogged(file: ChromePolicyFile) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            guard let path = chrome.path(file) else { return Self.expectNoUserCopy(daemon, chrome) }
            pause(0.5)
            #expect(!daemon.logText().contains(repairedLine), "a write caused by a command is not a repair, yet the log says:\n\(daemon.logText())")
            try FileManager.default.removeItem(atPath: path)
            let back = waitUntil(timeout: 1.0, interval: 0.01) { isRight(path, list: Self.youtube) }
            #expect(back != nil, "\(path) was not restored within 1 s")
            #expect(daemon.logContains(repairedLine), "the repair was not logged:\n\(daemon.logText())")
        }
    }

    // The whole ManagedPreferences folder removed (both files and both folders): the next pass recreates the folders and both files.
    @Test func aDeletedManagedPreferencesFolderIsRecreatedWithBothFilesWithinOneSecond() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            forceRemoveTree(chrome.directory)
            try #require(!exists(chrome.directory))
            let back = waitUntil(timeout: 1.0, interval: 0.01) { chrome.all.allSatisfy { isRight($0, list: Self.youtube) } }
            #expect(back != nil, "the folder and files were not recreated within 1 s; found \(regularFiles(under: chrome.directory))")
            #expect(permissions(of: chrome.directory) == 0o755)
            #expect(daemon.logContains(repairedLine))
        }
    }

    // 03 § ChromePolicyEnforcer "Writing": a file that is not a valid property list is treated as empty and replaced. Every kind of damage, in each file, is repaired within one second to exactly {URLBlocklist}, mode 0644 and an XML property list, and the repair is logged.
    @Test(arguments: ChromePolicyFile.allCases, ChromeTamper.allCases)
    func garbageContentIsRepairedWithinOneSecond(file: ChromePolicyFile, damage: ChromeTamper) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            guard let path = chrome.path(file) else { return Self.expectNoUserCopy(daemon, chrome) }
            pause(0.4)
            try damage.bytes.write(to: URL(fileURLWithPath: path))
            let repaired = waitUntil(timeout: 1.0, interval: 0.01) { isRight(path, list: Self.youtube) }
            #expect(repaired != nil, "\(damage) in \(path) was not repaired within 1 s; the file now holds \(String(describing: readText(path)))")
            #expect(plistFormat(path) == .xml)
            #expect(daemon.logContains(repairedLine))
        }
    }

    // The mode of a file Chrome (running as the user) must be able to read is 0644. A file left at a stricter or looser mode is put back within one second: with 0600 Chrome would silently lose the whole block list. The content is untouched in these cases, so only the mode shows whether the pass cares.
    @Test(arguments: ChromePolicyFile.allCases, [0o600, 0o640, 0o666])
    func aChangedFileModeIsRepairedWithinOneSecond(file: ChromePolicyFile, mode: Int) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            guard let path = chrome.path(file) else { return Self.expectNoUserCopy(daemon, chrome) }
            pause(0.4)
            try chmodPath(path, mode_t(mode))
            try #require(permissions(of: path) == mode, "the test could not change the mode")
            let repaired = waitUntil(timeout: 1.0, interval: 0.01) { permissions(of: path) == 0o644 }
            #expect(repaired != nil, "a file with mode \(String(mode, radix: 8)) still has mode \(String(describing: permissions(of: path).map { String($0, radix: 8) })) after 1 s")
            #expect(listed(path) == Self.youtube)
        }
    }

    // A valid file whose list was edited by hand (emptied, deleted, padded, or given the wrong type) is repaired to the right list within one second, and the other keys an administrator put there are kept (03 "Content rules": merged keeps every other key).
    @Test(arguments: ChromeListEdit.allCases)
    func aHandEditedListIsRepairedAndTheOtherKeysAreKept(edit: ChromeListEdit) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            pause(0.4)
            for (index, path) in chrome.all.enumerated() {
                try editPlist(at: path) { plist in
                    plist["HomepageLocation"] = "https://home-\(index).example/"
                    edit.apply(to: &plist)
                }
            }
            let repaired = waitUntil(timeout: 1.0, interval: 0.01) { chrome.all.allSatisfy { listed($0) == Self.youtube } }
            #expect(repaired != nil, "the list was not repaired after \(edit); files now: \(chrome.all.map { String(describing: readPlist($0)) })")
            for (index, path) in chrome.all.enumerated() {
                #expect(readPlist(path)?["HomepageLocation"] as? String == "https://home-\(index).example/", "the hand-added key was lost from \(path)")
                #expect(readPlist(path)?.count == 2, "\(path) holds \(String(describing: readPlist(path)?.keys.sorted()))")
            }
            #expect(daemon.logContains(repairedLine))
        }
    }

    // 03 "Writing": a target that is a symlink is replaced, never followed. An attacker (or a mistake) leaves a link where the file belongs; the pass puts a regular file there and the file the link pointed at is not touched. The decoy lives outside ManagedPreferences; the link is replaced whether the decoy holds another list, the right list, garbage, or does not exist.
    @Test(arguments: ChromePolicyFile.allCases, ["decoy with another list", "decoy with the right list", "decoy that is garbage", "link to nowhere"])
    func aSymlinkInPlaceOfTheFileIsReplacedAndItsTargetLeftAlone(file: ChromePolicyFile, kind: String) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            guard let path = chrome.path(file) else { return Self.expectNoUserCopy(daemon, chrome) }
            let decoy = daemon.root + "/decoy.plist"
            var decoyBytes: Data?
            switch kind {
            case "decoy with another list":
                try writePlist([blocklistKey: ["decoy.example"], "Keep": "me"], to: decoy)
                decoyBytes = FileManager.default.contents(atPath: decoy)
            case "decoy with the right list":
                // Even a link whose target already holds the right list is replaced: a link lets whoever owns the target change the policy later.
                try writePlist([blocklistKey: Self.youtube], to: decoy)
                try chmodPath(decoy, 0o644)
                decoyBytes = FileManager.default.contents(atPath: decoy)
            case "decoy that is garbage":
                decoyBytes = Data("DECOY — not a plist\n".utf8)
                try decoyBytes?.write(to: URL(fileURLWithPath: decoy))
            default:
                break
            }
            pause(0.4)
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: decoy)
            let replaced = waitUntil(timeout: 1.5, interval: 0.01) {
                (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular && isRight(path, list: Self.youtube)
            }
            let type = (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) ?? nil
            #expect(replaced != nil, "\(path) is still \(String(describing: type)) after 1.5 s")
            #expect(decoyBytes == nil ? !exists(decoy) : FileManager.default.contents(atPath: decoy) == decoyBytes, "the file behind the link was written through the link (kind: \(kind))")
        }
    }

    // 03 "Writing": a pass that finds a file already right does not write it. Over 1.5 s (about seven passes) neither the inode nor the modification time of either file changes. A hand edit afterwards is repaired, which shows the passes were running.
    @Test func passesThatFindTheFilesRightDoNotWriteThem() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            pause(0.6)
            let first = chrome.all.map { identity(of: $0) }
            try #require(first.allSatisfy { $0 != nil })
            pause(1.5)
            #expect(chrome.all.map { identity(of: $0) } == first, "an already-correct policy file was rewritten")
            if let path = chrome.all.first {
                try editPlist(at: path) { $0[blocklistKey] = [String]() }
                #expect(waitUntil(timeout: 1.0, interval: 0.01) { listed(path) == Self.youtube } != nil, "the passes stopped enforcing")
            }
        }
    }

    // MARK: other keys

    // 03 "Content rules": a real company policy is never lost. Keys an administrator added by hand (strings, booleans, numbers, arrays, nested dictionaries) survive the next add with their values and types. The two files differ on purpose (a different HomepageLocation in each), so a daemon that copied one file's keys into the other, or built both from one dictionary, is caught.
    @Test func handAddedKeysSurviveTheNextAddInEachFileSeparately() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            let shared: [String: Any] = [
                "ShowHomeButton": true,
                "RestoreOnStartup": 4,
                "RestoreOnStartupURLs": ["https://a.example/", "https://b.example/"],
                "ManagedBookmarks": [["name": "Wiki", "url": "https://wiki.example/"]],
                "ProxySettings": ["ProxyMode": "direct"],
            ]
            for (index, path) in chrome.all.enumerated() {
                try editPlist(at: path) { plist in
                    plist.merge(shared) { _, new in new }
                    plist["HomepageLocation"] = "https://home-\(index).example/"
                }
            }
            // The edits must not be treated as damage: wait until the passes have looked at them.
            pause(0.5)
            try daemon.block("reddit.com")
            let expected = ExpectedHosts.expand(all: ["youtube.com", "reddit.com"])
            for (index, path) in chrome.all.enumerated() {
                let plist = readPlist(path)
                var wanted = shared
                wanted["HomepageLocation"] = "https://home-\(index).example/"
                wanted[blocklistKey] = expected
                #expect(isExactly(plist, wanted), "\(path) now holds \(String(describing: plist))")
                // A boolean must still be a boolean, not the number 1.
                let flag = plist?["ShowHomeButton"] as? NSNumber
                #expect(flag.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true, "ShowHomeButton lost its boolean type")
            }
        }
    }

    // 03 "Content rules": with nothing blocked the file holds no URLBlocklist, but a file that has only other keys is left exactly as it is (no rewrite). A file that holds nothing but a URLBlocklist someone planted is deleted ("nothing else is left").
    @Test func withNothingBlockedAFileOfOtherKeysIsLeftAloneAndAFileOfOnlyABlocklistIsDeleted() throws {
        try withDaemon { daemon in
            let chrome = try daemon.chromePaths()
            pause(0.4)
            try writePlist(["HomepageLocation": "https://intranet.example/"], to: chrome.machine)
            let before = identity(of: chrome.machine)
            let bytes = FileManager.default.contents(atPath: chrome.machine)
            if let userPath = chrome.user { try writePlist([blocklistKey: ["planted.example"]], to: userPath) }
            pause(1.0)
            #expect(identity(of: chrome.machine) == before, "a file without a URLBlocklist was rewritten while nothing was blocked")
            #expect(FileManager.default.contents(atPath: chrome.machine) == bytes)
            if let userPath = chrome.user { #expect(!exists(userPath), "a file holding only a planted URLBlocklist must be deleted when nothing is blocked") }
        }
    }

    // A URLBlocklist planted next to other keys while nothing is blocked is removed and the other keys stay.
    @Test func withNothingBlockedAPlantedBlocklistIsRemovedAndTheOtherKeysStay() throws {
        try withDaemon { daemon in
            let chrome = try daemon.chromePaths()
            pause(0.4)
            try writePlist([blocklistKey: ["planted.example"], "HomepageLocation": "https://intranet.example/"], to: chrome.machine)
            let cleaned = waitUntil(timeout: 1.0, interval: 0.01) { isExactly(readPlist(chrome.machine), ["HomepageLocation": "https://intranet.example/"]) }
            #expect(cleaned != nil, "the machine file now holds \(String(describing: readPlist(chrome.machine)))")
        }
    }

    // 03 "Writing": a file that is not a valid property list counts as empty, and with nothing blocked an empty file is deleted. A symlink in place of the file is removed without being followed: the file it points at keeps every byte.
    @Test(arguments: ChromePolicyFile.allCases, ["garbage", "symlink to a decoy"])
    func withNothingBlockedADamagedFileOrALinkInItsPlaceIsRemovedWithoutTouchingTheTarget(file: ChromePolicyFile, kind: String) throws {
        try withDaemon { daemon in
            let chrome = try daemon.chromePaths()
            guard let path = chrome.path(file) else { return Self.expectNoUserCopy(daemon, chrome) }
            pause(0.4)
            let decoy = daemon.root + "/decoy.plist"
            try writePlist(["HomepageLocation": "https://decoy.example/"], to: decoy)
            let decoyBytes = FileManager.default.contents(atPath: decoy)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if kind == "garbage" {
                try ChromeTamper.notAPlistAtAll.bytes.write(to: URL(fileURLWithPath: path))
            } else {
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: decoy)
            }
            let removed = waitUntil(timeout: 1.0, interval: 0.01) { !exists(path) }
            #expect(removed != nil, "\(kind) at \(path) was not removed within 1 s")
            #expect(FileManager.default.contents(atPath: decoy) == decoyBytes, "the file behind the link was changed")
        }
    }

    // MARK: nothing blocked

    // Nothing blocked means no policy file (the design deletes a file when nothing else is left) and no temp file anywhere in ManagedPreferences, on a fresh daemon and again after a site has been blocked and its unblock countdown finished.
    @Test func nothingBlockedMeansNeitherFileExistsAndNoTempFilesAreLeftBehind() throws {
        try withDaemon { daemon in
            let chrome = try daemon.chromePaths()
            pause(1.0)
            #expect(chrome.all.allSatisfy { !exists($0) }, "a fresh daemon with nothing blocked must not write a policy file")
            #expect(regularFiles(under: chrome.directory) == [], "found \(regularFiles(under: chrome.directory))")
            // About five passes ran and found everything already right, so none of them repaired anything.
            #expect(!daemon.logText().contains(repairedLine), "passes that had nothing to do logged a repair:\n\(daemon.logText())")

            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            #expect(chrome.all.allSatisfy { listed($0) == ExpectedHosts.expand("reddit.com") })
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            let gone = waitUntil(timeout: 5.0, interval: 0.02) { chrome.all.allSatisfy { !exists($0) } }
            #expect(gone != nil, "the policy files still exist after the unblock finished: \(chrome.all.map { String(describing: listed($0)) })")
            pause(0.6)
            #expect(chrome.all.allSatisfy { !exists($0) }, "a policy file came back after the last site was unblocked")
            #expect(regularFiles(under: chrome.directory) == [], "found \(regularFiles(under: chrome.directory))")
            #expect(daemon.hosts().beginCount == 0, "the hosts section is gone too")
        }
    }

    // MARK: pending unblocks

    // 03 "Content rules": a site with a pending unblock stays listed until its countdown ends. With youtube.com counting down (2 s delay) and reddit.com staying, the list holds both until the countdown has run out, and then exactly reddit.com's hosts. The stopwatch starts before the request, so the list can never be seen shortened before 2 s.
    @Test func aSiteStaysInTheListDuringItsUnblockCountdownAndLeavesWhenItEnds() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com", "reddit.com")
            try daemon.requireTwoSecondDelay()
            let chrome = try daemon.chromePaths()
            let both = ExpectedHosts.expand(all: ["youtube.com", "reddit.com"])
            let redditOnly = ExpectedHosts.expand("reddit.com")
            let watch = Stopwatch()
            try daemon.send(.unblock, domain: "youtube.com", password: Self.password).requireOK()
            var shortenedAt: Double?
            while watch.elapsed < 1.5 {
                if chrome.all.contains(where: { listed($0) != both }) { shortenedAt = watch.elapsed; break }
                pause(0.02)
            }
            #expect(shortenedAt == nil, "the list changed \(String(describing: shortenedAt)) s into a 2 s countdown")
            let shortened = waitUntil(timeout: 4.0, interval: 0.02) { chrome.all.allSatisfy { listed($0) == redditOnly } }
            #expect(shortened != nil, "the list never dropped youtube.com; files hold \(chrome.all.map { String(describing: listed($0)) })")
            #expect(watch.elapsed >= 2.0, "the list was shortened after \(watch.elapsed) s, before the 2 s countdown was over")
            #expect(daemon.hosts().blocks("youtube.com") == false, "the hosts file has dropped youtube.com as well")
            #expect(chrome.all.allSatisfy { isRight($0, list: redditOnly) })
        }
    }

    // A cancelled unblock changes nothing: the list never lost the site.
    @Test func cancellingAnUnblockLeavesTheListUnchangedPastTheDelay() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            try daemon.send(.unblock, domain: "youtube.com", password: Self.password).requireOK()
            try daemon.send(.cancelUnblock, domain: "youtube.com").requireOK()
            pause(2.6)
            #expect(chrome.all.allSatisfy { isRight($0, list: Self.youtube) })
        }
    }

    // MARK: write failure

    // 03 § ChromePolicyEnforcer: when a write fails the enforcer returns false and logs; 03 § DaemonRuntime: the hosts file is enforced regardless. The ManagedPreferences folder is made read-only (0555) before the first add, so no temp file can be created in it. The add still succeeds, the hosts file is written, nothing about Chrome appears on disk, the failure is logged, and the daemon keeps running. When the folder is writable again the next pass writes both files within one second without any command. The permissions are restored in a defer so a failed expectation cannot leave an undeletable folder behind.
    @Test(.enabled(if: geteuid() != 0))
    func aChromeWriteFailureIsLoggedAndLeavesTheHostsFileEnforcedAndTheFilesComeBackOnceWritingWorks() throws {
        try withDaemon { daemon in
            let chrome = try daemon.chromePaths()
            try daemon.setUp()
            try FileManager.default.createDirectory(atPath: chrome.directory, withIntermediateDirectories: false)
            defer { try? chmodPath(chrome.directory, 0o755) }
            try chmodPath(chrome.directory, 0o555)
            try daemon.send(.add, domain: "youtube.com").requireOK()
            let hosts = ExpectedHosts.text(blocking: Self.youtube)
            #expect(daemon.hostsText() == hosts, "a Chrome write failure must not stop the hosts file from being enforced")
            #expect(daemon.logContains("Chrome", within: 1.5), "the failed write was not logged:\n\(daemon.logText())")
            #expect(regularFiles(under: chrome.directory) == [], "found \(regularFiles(under: chrome.directory))")
            pause(0.5)
            #expect(daemon.isRunning)
            #expect(try daemon.status().blocked.map(\.domain) == ["youtube.com"])

            try chmodPath(chrome.directory, 0o755)
            let back = waitUntil(timeout: 1.5, interval: 0.01) { chrome.all.allSatisfy { isRight($0, list: Self.youtube) } }
            #expect(back != nil, "the files were not written once the folder became writable; found \(regularFiles(under: chrome.directory))")
        }
    }

    // MARK: restart

    // A stopped daemon leaves the block in place (only an uninstall clears it), and policy files deleted while it is down are written again by the pass the daemon runs at startup, before any client connects (03 § DaemonRuntime startup step 5). The daemon has a 60 s tick and the test never connects to it, so neither a tick nor a command can explain the files coming back. That pass is not caused by a command, so it is logged as a repair. Both ways of stopping the daemon are tried.
    @Test(arguments: StopMethod.allCases)
    func policyFilesDeletedWhileTheDaemonIsDownComeBackAtStartup(stop: StopMethod) throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "youtube.com")
            let chrome = try daemon.chromePaths()
            daemon.stop(stop)
            #expect(chrome.all.allSatisfy { listed($0) == Self.youtube }, "stopping the daemon (\(stop.testDescription)) must not clear the block")
            #expect(!daemon.logText().contains(repairedLine))
            for path in chrome.all { try FileManager.default.removeItem(atPath: path) }
            try daemon.start(serve: false)
            let back = waitUntil(timeout: 1.5, interval: 0.01) { chrome.all.allSatisfy { isRight($0, list: Self.youtube) } }
            #expect(back != nil, "the files were not written again by the startup pass (\(stop.testDescription))")
            #expect(daemon.logContains(repairedLine), "the startup repair was not logged:\n\(daemon.logText())")
        }
    }

    // MARK: uninstall

    // 03 § Uninstaller and § ChromePolicyEnforcer "Uninstall": the uninstall removes URLBlocklist from both files in the same step that removes the hosts section. When the files hold nothing else they are deleted; when an administrator's keys are there, those stay and only URLBlocklist goes. The checks run once the daemon has exited with code 0, so a late pass cannot be hiding a leftover.
    @Test(arguments: [false, true])
    func theSandboxUninstallRemovesUrlBlocklistFromBothFiles(otherKeysPresent: Bool) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "youtube.com")
            try daemon.requireTwoSecondDelay()
            let chrome = try daemon.chromePaths()
            if otherKeysPresent {
                for (index, path) in chrome.all.enumerated() { try editPlist(at: path) { $0["HomepageLocation"] = "https://home-\(index).example/" } }
                pause(0.5)
            }
            #expect(chrome.all.allSatisfy { listed($0) == Self.youtube }, "the list must be in place before the uninstall")
            try daemon.send(.uninstall, password: Self.password).requireOK()
            // The list stays in force during the countdown.
            #expect(chrome.all.allSatisfy { listed($0) == Self.youtube }, "the list must stay in place while the uninstall counts down")
            let exit = try #require(daemon.waitForExit(timeout: 6.0), "the daemon never exited after the uninstall delay")
            #expect(exit.status == 0 && !exit.killedBySignal)
            #expect(daemon.hostsText() == StandardHosts.text, "the hosts section is removed in the same step")
            for (index, path) in chrome.all.enumerated() {
                if otherKeysPresent {
                    #expect(isExactly(readPlist(path), ["HomepageLocation": "https://home-\(index).example/"]), "\(path) now holds \(String(describing: readPlist(path)))")
                } else {
                    #expect(!exists(path), "\(path) must be deleted: nothing else is left in it")
                }
            }
            #expect(regularFiles(under: chrome.directory).count == (otherKeysPresent ? chrome.all.count : 0), "found \(regularFiles(under: chrome.directory))")
        }
    }

    // MARK: user copy absent

    // The per-user file belongs to the console user; with root at the console it is not written. Called when a test is asked about the per-user file on a Mac where nobody is logged in: the file must not exist.
    static func expectNoUserCopy(_ daemon: SandboxDaemon, _ chrome: ChromePolicyPaths) {
        #expect(chrome.consoleUser == nil, "the per-user file was asked for although there is a console user")
        let entries = daemon.listing(of: chrome.directory)
        #expect(entries.filter { $0 != policyFileName }.isEmpty, "with root at the console only the machine-wide file is written, found \(entries)")
    }
}
