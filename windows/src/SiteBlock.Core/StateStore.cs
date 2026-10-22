using System.Text.Json;

namespace SiteBlock.Core;

/// <summary>Thrown by <see cref="StateStore.Save"/> when a state file could not be written. Its message reads "SiteBlock could not save its state: " followed by the detail.</summary>
public sealed class StateStoreException(string detail, Exception? inner = null) : Exception($"SiteBlock could not save its state: {detail}", inner)
{
    /// <summary>What went wrong, without the leading sentence.</summary>
    public string Detail { get; } = detail;
}

/// <summary>
/// Reads and writes state.json safely, and keeps an optional second copy (the backup) so deleting or wiping one file cannot lose the block list.
/// It is not thread-safe; the service uses it from its one engine thread.
/// </summary>
public sealed class StateStore
{
    // The exact bytes this store last wrote or last loaded from the primary file; MatchesLastSave compares the files on disk against them. Null until the first save or successful load.
    private byte[]? _lastKnownBytes;

    /// <summary>Creates a store for the given state file location. Pass a backup path to also keep a second copy; without one the store behaves as a single-file store.</summary>
    public StateStore(string path, string? backupPath = null)
    {
        Path = path ?? throw new ArgumentNullException(nameof(path));
        BackupPath = backupPath;
    }

    /// <summary>The location of the state file.</summary>
    public string Path { get; }

    /// <summary>The location of the backup copy, or null when no backup is kept.</summary>
    public string? BackupPath { get; }

    /// <summary>
    /// Returns the primary file's state when it decodes. When the primary is missing or unusable, returns the backup's state if that decodes, otherwise null, so the service starts fresh instead of crashing in a restart loop.
    /// A primary that exists but holds content that cannot be decoded (or cannot be read for any reason other than another program holding it open) is renamed to state.json.corrupt-&lt;unix time&gt; so it is kept for inspection.
    /// A file that another program holds open without sharing (Windows sharing or lock violation, as an antivirus scan causes) is read again for a few seconds; when it stays locked, Load throws
    /// <see cref="StateStoreException"/> instead of treating it as damaged, because starting fresh would let the next save overwrite the real blocks and password.
    /// </summary>
    public PersistedState? Load()
    {
        // A folder sitting at the file's path also counts as "exists", as Foundation's fileExists does; it cannot be read, so it is moved aside like a damaged file.
        if (Directory.Exists(Path))
        {
            MoveAsideCorruptFile();
        }
        else if (File.Exists(Path))
        {
            try
            {
                byte[]? data = ReadShared(Path);
                if (data is not null)
                {
                    PersistedState state = JsonCoding.Decode<PersistedState>(data);
                    // Remember what the primary held, so MatchesLastSave can tell later whether either file drifted from it (for example a backup that does not exist yet).
                    _lastKnownBytes = data;
                    return state;
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
            {
                MoveAsideCorruptFile();
            }
        }
        // The backup is only a fallback: it is never renamed, because the next save overwrites it anyway.
        if (BackupPath is null) return null;
        byte[]? backup;
        try
        {
            backup = ReadShared(BackupPath);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return null;
        }
        if (backup is null || JsonCoding.TryDecode<PersistedState>(backup) is not PersistedState fromBackup) return null;
        // The primary is missing or was just moved aside, so the next MatchesLastSave reports a mismatch and the caller writes the primary back.
        _lastKnownBytes = backup;
        return fromBackup;
    }

    // How often, and how far apart, a file held open by another program is tried again (about 3 seconds in all).
    private const int LockedRetries = 10;
    private static readonly TimeSpan LockedRetryDelay = TimeSpan.FromMilliseconds(300);

    /// <summary>True for a Windows sharing violation (32) or lock violation (33): another program has the file open and is not sharing it, which passes on its own.</summary>
    private static bool IsLocked(IOException error) => (error.HResult & 0xFFFF) is 32 or 33;

    /// <summary>
    /// Reads a whole file while letting other programs read, write, rename or delete it at the same time, so this read never blocks the service's own save. Returns null when the file is not there.
    /// A sharing or lock violation is tried again for about 3 seconds and then reported as <see cref="StateStoreException"/>; any other failure is thrown as it is.
    /// </summary>
    private static byte[]? ReadShared(string path)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var copy = new MemoryStream();
                stream.CopyTo(copy);
                return copy.ToArray();
            }
            catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
            {
                return null;
            }
            catch (IOException error) when (IsLocked(error))
            {
                if (attempt >= LockedRetries) throw new StateStoreException($"{path} is held open by another program", error);
                Thread.Sleep(LockedRetryDelay);
            }
        }
    }

    /// <summary>Renames the unusable state file so it is kept for inspection but no longer in the way. A failed rename is ignored; the next successful save replaces the file anyway.</summary>
    private void MoveAsideCorruptFile()
    {
        long stamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        string target = $"{Path}.corrupt-{stamp}";
        // Two corrupt files in the same second must not overwrite each other.
        int suffix = 1;
        while (File.Exists(target) || Directory.Exists(target))
        {
            target = $"{Path}.corrupt-{stamp}-{suffix}";
            suffix++;
        }
        try
        {
            if (Directory.Exists(Path)) Directory.Move(Path, target);
            else File.Move(Path, target);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Ignored on purpose: the next save writes a good file over it.
        }
    }

    /// <summary>
    /// Writes the primary file and then the backup (when there is one). Each write is atomic: encode with sorted keys, write to a temp file next to the target (readable only by its owner on macOS and Linux),
    /// flush it to disk, then rename it over the target, so each file is always either the old version or the new version, never half-written.
    /// Throws <see cref="StateStoreException"/> when either write fails; the primary is still written when only the backup fails.
    /// </summary>
    public void Save(PersistedState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        byte[] data;
        try
        {
            data = JsonCoding.Encode(state);
        }
        catch (JsonException error)
        {
            throw new StateStoreException($"encoding failed: {error.Message}", error);
        }
        WriteAtomically(data, Path);
        // The primary is on disk now, so remember its bytes even if the backup write below fails; MatchesLastSave then reports the missing backup and the caller retries.
        _lastKnownBytes = data;
        if (BackupPath is not null) WriteAtomically(data, BackupPath);
    }

    /// <summary>
    /// True when every file this store keeps (the primary, and the backup if there is one) exists and holds exactly the bytes this store last wrote or loaded.
    /// Returns true when the store has not written or loaded anything yet, because there is nothing to compare against.
    /// </summary>
    public bool MatchesLastSave()
    {
        if (_lastKnownBytes is not byte[] expected) return true;
        var paths = new List<string> { Path };
        if (BackupPath is not null) paths.Add(BackupPath);
        foreach (string path in paths)
        {
            // A missing or unreadable file counts as a mismatch.
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var copy = new MemoryStream();
                stream.CopyTo(copy);
                if (!copy.ToArray().AsSpan().SequenceEqual(expected)) return false;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>Writes the data to a temp file beside the target (creating the folder when it is missing, owner-only on macOS and Linux) and renames it over the target.</summary>
    private static void WriteAtomically(byte[] data, string path)
    {
        string directory = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path)) ?? ".";
        if (!Directory.Exists(directory))
        {
            try
            {
                if (OperatingSystem.IsWindows()) Directory.CreateDirectory(directory);
                else Directory.CreateDirectory(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw new StateStoreException($"could not create {directory}: {error.Message}", error);
            }
        }

        string tempPath = path + ".tmp";
        // Remove a leftover temp file first, so CreateNew below guarantees a brand-new file and a planted link at that name is never written through.
        try
        {
            File.Delete(tempPath);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // A temp name that cannot be removed makes CreateNew fail below, which reports the problem.
        }
        try
        {
            var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None };
            // Mode 0600 is set when the file is created, so the data is never readable by others whatever the umask is. Windows gets its access list from the folder, which the service sets.
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var stream = new FileStream(tempPath, options))
            {
                stream.Write(data);
                // Flush to disk before the rename, so a crash cannot leave the new name pointing at empty data.
                stream.Flush(flushToDisk: true);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            TryDelete(tempPath);
            throw new StateStoreException($"could not write {tempPath}: {error.Message}", error);
        }
        // The rename is tried again for a moment when another program (such as an antivirus scan) holds the old file open without letting it be replaced.
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                File.Move(tempPath, path, overwrite: true);
                break;
            }
            catch (IOException error) when (IsLocked(error) && attempt < 5)
            {
                Thread.Sleep(TimeSpan.FromMilliseconds(100));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                TryDelete(tempPath);
                throw new StateStoreException($"could not replace {path}: {error.Message}", error);
            }
        }
    }

    /// <summary>Deletes a file, ignoring any failure.</summary>
    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Nothing more can be done; the next save removes the leftover first.
        }
    }
}
