import Foundation

/// The reason a state file could not be written.
public enum StateStoreError: Error, LocalizedError, Equatable {
    case writeFailed(String)

    /// The sentence describing the failure.
    public var errorDescription: String? {
        switch self {
        case .writeFailed(let detail): return "SiteBlock could not save its state: \(detail)"
        }
    }
}

/// Reads and writes state.json safely.
public final class StateStore {
    /// The location of the state file.
    public let url: URL

    /// Creates a store for the given state file location.
    public init(url: URL) {
        self.url = url
    }

    /// Returns the saved state, or nil when there is no file. A file that exists but cannot be read or decoded is renamed to state.json.corrupt-<unix time> and nil is returned, so the daemon starts fresh instead of crashing in a restart loop.
    public func load() -> PersistedState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONCoding.decoder.decode(PersistedState.self, from: data)
        } catch {
            moveAsideCorruptFile()
            return nil
        }
    }

    /// Renames the unusable state file so it is kept for inspection but no longer in the way. A failed rename is ignored; the next successful save replaces the file anyway.
    private func moveAsideCorruptFile() {
        let stamp = Int(Date().timeIntervalSince1970)
        var target = url.path + ".corrupt-\(stamp)"
        // Two corrupt files in the same second must not overwrite each other, because rename replaces an existing target.
        var suffix = 1
        while FileManager.default.fileExists(atPath: target) {
            target = url.path + ".corrupt-\(stamp)-\(suffix)"
            suffix += 1
        }
        _ = rename(url.path, target)
    }

    /// Writes the state atomically: encode with sorted keys, write to state.json.tmp in the same folder with mode 0600, then rename over state.json. The file is always either the old version or the new one, never half-written.
    public func save(_ state: PersistedState) throws {
        let data: Data
        do { data = try JSONCoding.encoder.encode(state) } catch { throw StateStoreError.writeFailed("encoding failed: \(error.localizedDescription)") }

        let directory = url.deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: directory) {
            do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { throw StateStoreError.writeFailed("could not create \(directory): \(error.localizedDescription)") }
        }

        let tempPath = url.path + ".tmp"
        // Remove a leftover temp file first, so O_EXCL below guarantees a brand-new file and a planted symlink can never be followed.
        _ = unlink(tempPath)
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd < 0 { throw StateStoreError.writeFailed("could not create \(tempPath): \(String(cString: strerror(errno)))") }
        do {
            try writeAll(data, to: fd)
            // Mode 0600 is set on the open file itself, so the data is never readable by others, whatever the process umask is.
            if fchmod(fd, 0o600) != 0 { throw StateStoreError.writeFailed("could not set permissions: \(String(cString: strerror(errno)))") }
            // Flush to disk before the rename, so a crash cannot leave the new name pointing at empty data.
            if fsync(fd) != 0 { throw StateStoreError.writeFailed("could not flush to disk: \(String(cString: strerror(errno)))") }
        } catch {
            close(fd)
            _ = unlink(tempPath)
            throw error
        }
        close(fd)
        if rename(tempPath, url.path) != 0 {
            let detail = String(cString: strerror(errno))
            _ = unlink(tempPath)
            throw StateStoreError.writeFailed("could not replace \(url.path): \(detail)")
        }
    }

    /// Writes every byte of the data to the file descriptor, retrying after interrupts and partial writes.
    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw StateStoreError.writeFailed("write failed: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
    }
}
