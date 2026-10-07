import Foundation

// Small helpers shared by every integration test: a failure type, time measuring and polling.

// A problem found while setting up or driving a test. It is thrown so the test is reported as failed with this message.
struct TestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// Throws a TestFailure when the condition is false. Used for preconditions, where carrying on would only produce confusing follow-up failures.
func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw TestFailure(message()) }
}

// Turns a ContinuousClock duration into seconds.
func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

// A stopwatch that starts when it is created and reports the seconds that have passed.
struct Stopwatch {
    private let start = ContinuousClock.now
    var elapsed: Double { seconds(ContinuousClock.now - start) }
}

// Sleeps the calling thread for the given number of seconds.
func pause(_ delay: Double) {
    Thread.sleep(forTimeInterval: delay)
}

// Checks the condition every `interval` seconds until it is true or `timeout` seconds have passed. Returns the seconds it took, or nil on timeout.
@discardableResult
func waitUntil(timeout: Double, interval: Double = 0.02, _ condition: () -> Bool) -> Double? {
    let watch = Stopwatch()
    while true {
        if condition() { return watch.elapsed }
        if watch.elapsed >= timeout { return nil }
        Thread.sleep(forTimeInterval: interval)
    }
}

// Reads a text file, or nil when it does not exist or is not UTF-8.
func readText(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(data: data, encoding: .utf8)
}

// Writes text over a file in place (like `echo text > file`), without the write-then-rename a careful program would use.
func writeText(_ text: String, to path: String) throws {
    try text.write(toFile: path, atomically: false, encoding: .utf8)
}

// Reads a JSON file into a dictionary, or nil when the file is missing or is not a JSON object.
func readJSONObject(_ path: String) -> NSDictionary? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
}

// Rewrites a JSON state file after letting `change` edit its top-level keys; every other key is kept as it was.
func editJSONObject(at path: String, _ change: (inout [String: Any]) -> Void) throws {
    guard let data = FileManager.default.contents(atPath: path), var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure("\(path) is missing or is not a JSON object")
    }
    change(&object)
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
}

// The permission bits (like 0o600) of a file, or nil when it does not exist.
func permissions(of path: String) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}

// Sets the permission bits of a path (like `chmod 0555 path`). Throws when the change fails, so a test never goes on with permissions it did not get.
func chmodPath(_ path: String, _ mode: mode_t) throws {
    if chmod(path, mode) != 0 { throw TestFailure("chmod \(String(mode, radix: 8)) \(path) failed: \(String(cString: strerror(errno)))") }
}

// Which file a path points at and when it last changed: the inode number and the last-modified time. Writing the file in place changes the time, and renaming a new file over it changes the inode, so any rewrite makes two identities differ.
struct FileIdentity: Equatable {
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
}

// The identity of the file at a path, or nil when it does not exist.
func identity(of path: String) -> FileIdentity? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return FileIdentity(inode: UInt64(info.st_ino), modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
}

// Deletes a folder tree even when a test left parts of it read-only (like `chmod -R u+rwx` followed by `rm -rf`). Folders are made owner-writable before their contents are listed and deleted; symbolic links are deleted without being followed.
func forceRemoveTree(_ path: String) {
    var info = stat()
    guard lstat(path, &info) == 0 else { return }
    if (info.st_mode & S_IFMT) == S_IFDIR {
        _ = chmod(path, info.st_mode | 0o700)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { forceRemoveTree(path + "/" + name) }
    }
    try? FileManager.default.removeItem(atPath: path)
}
