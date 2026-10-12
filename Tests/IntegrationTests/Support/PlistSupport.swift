import Foundation

// Helpers shared by the browser policy tests (Chrome, Edge, Brave and Firefox files): reading, writing and editing property list files the way a browser or an administrator would.

// True when something (a file, folder or link, even a dangling one) exists at the path.
func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

// The top-level dictionary of a property list file, or nil when the file is missing, is not a property list, or is not a dictionary.
func readPlist(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
}

// The storage format of a property list file (xml1 or binary1), or nil when it cannot be parsed.
func plistFormat(_ path: String) -> PropertyListSerialization.PropertyListFormat? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    var format = PropertyListSerialization.PropertyListFormat.binary
    guard (try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)) != nil else { return nil }
    return format
}

// Writes a dictionary as an XML property list through a rename, so the daemon can never read a half-written file.
func writePlist(_ plist: [String: Any], to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

// Reads a file's dictionary (empty when missing), lets the change edit it, and writes it back.
func editPlist(at path: String, _ change: (inout [String: Any]) -> Void) throws {
    var plist = readPlist(path) ?? [:]
    change(&plist)
    try writePlist(plist, to: path)
}

// True when the dictionary has exactly the given keys with equal values.
func isExactly(_ plist: [String: Any]?, _ expected: [String: Any]) -> Bool {
    guard let plist else { return false }
    return NSDictionary(dictionary: plist).isEqual(to: expected)
}

// The relative paths of every regular file under a folder (empty when the folder does not exist), sorted. Hidden files are included, so a leftover temp file with a dotted name is seen.
func regularFiles(under directory: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
    var found: [String] = []
    for case let relative as String in walker {
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory + "/" + relative)
        if (attributes?[.type] as? FileAttributeType) != .typeDirectory { found.append(relative) }
    }
    return found.sorted()
}

