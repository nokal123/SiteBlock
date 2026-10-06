import Foundation

// Finds the built `siteblockd` and `siteblock` programs that the integration tests start.
enum Binaries {
    // The folder that holds the built programs. It is the folder that contains the running test bundle (the .xctest folder), unless the environment variable SITEBLOCK_BIN_DIR names another one. Falls back to the package's own .build/debug folder.
    static let productsDirectory: String? = {
        if let override = ProcessInfo.processInfo.environment["SITEBLOCK_BIN_DIR"], !override.isEmpty { return override }
        for index in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(index) else { continue }
            let name = String(cString: cName)
            if let range = name.range(of: ".xctest/") {
                let bundlePath = String(name[..<name.index(before: range.upperBound)])
                return URL(fileURLWithPath: bundlePath).deletingLastPathComponent().path
            }
        }
        // Last resort: walk up from this source file to the folder holding Package.swift.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory.appendingPathComponent(".build/debug").path
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }()

    // The full path of a built program, or a TestFailure that says to build it first.
    static func path(_ name: String) throws -> String {
        guard let directory = productsDirectory else { throw TestFailure("could not locate the build products folder") }
        let path = directory + "/" + name
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw TestFailure("\(path) does not exist; run `swift build` first so \(name) is built")
        }
        return path
    }
}
