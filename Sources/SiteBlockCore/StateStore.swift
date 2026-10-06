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

/// Reads and writes state.json safely, and keeps an optional second copy (the backup) so deleting or wiping one file cannot lose the block list.
public final class StateStore {
    /// The location of the state file.
    public let url: URL
    /// The location of the backup copy, or nil when no backup is kept.
    public let backupURL: URL?
    // The exact bytes this store last wrote or last loaded from the primary file; matchesLastSave compares the files on disk against them. Nil until the first save or successful load.
    private var lastKnownBytes: Data?

    /// Creates a store for the given state file location. Pass a backupURL to also keep a second copy; without one the store behaves as a single-file store.
    public init(url: URL, backupURL: URL? = nil) {
        self.url = url
        self.backupURL = backupURL
    }

    /// Returns the primary file's state when it decodes. When the primary is missing or unusable, returns the backup's state if that decodes, otherwise nil, so the daemon starts fresh instead of crashing in a restart loop. A primary that exists but cannot be read or decoded is renamed to state.json.corrupt-<unix time> so it is kept for inspection.
    public func load() -> PersistedState? {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let state = try JSONCoding.decoder.decode(PersistedState.self, from: data)
                // Remember what the primary held, so matchesLastSave can tell later whether either file drifted from it (for example a backup that does not exist yet).
                lastKnownBytes = data
                return state
            } catch {
                moveAsideCorruptFile()
            }
        }
        // The backup is only a fallback: it is never renamed, because the next save overwrites it anyway.
        guard let backupURL, let data = try? Data(contentsOf: backupURL), let state = try? JSONCoding.decoder.decode(PersistedState.self, from: data) else { return nil }
        // The primary is missing or was just moved aside, so the next matchesLastSave reports a mismatch and the caller writes the primary back.
        lastKnownBytes = data
        return state
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

    /// Writes the primary file and then the backup (when there is one). Each write is atomic: encode with sorted keys, write to a temp file next to the target with mode 0600, then rename over the target, so each file is always either the old version or the new version, never half-written. Throws when either write fails; the primary is still written when only the backup fails.
    public func save(_ state: PersistedState) throws {
        let data: Data
        do { data = try JSONCoding.encoder.encode(state) } catch { throw StateStoreError.writeFailed("encoding failed: \(error.localizedDescription)") }

        try writeAtomically(data, to: url.path)
        // The primary is on disk now, so remember its bytes even if the backup write below fails; matchesLastSave then reports the missing backup and the caller retries.
        lastKnownBytes = data
        if let backupURL { try writeAtomically(data, to: backupURL.path) }
    }

    /// True when every file this store keeps (the primary, and the backup if there is one) exists and holds exactly the bytes this store last wrote or loaded. Returns true when the store has not written or loaded anything yet, because there is nothing to compare against.
    public func matchesLastSave() -> Bool {
        guard let expected = lastKnownBytes else { return true }
        var paths = [url.path]
        if let backupURL { paths.append(backupURL.path) }
        for path in paths {
            // A missing or unreadable file counts as a mismatch.
            guard let onDisk = FileManager.default.contents(atPath: path), onDisk == expected else { return false }
        }
        return true
    }

    /// Writes the data to a temp file beside the target (creating the folder with mode 0700 when it is missing) and renames it over the target.
    private func writeAtomically(_ data: Data, to path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: directory) {
            do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { throw StateStoreError.writeFailed("could not create \(directory): \(error.localizedDescription)") }
        }

        let tempPath = path + ".tmp"
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
        if rename(tempPath, path) != 0 {
            let detail = String(cString: strerror(errno))
            _ = unlink(tempPath)
            throw StateStoreError.writeFailed("could not replace \(path): \(detail)")
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
