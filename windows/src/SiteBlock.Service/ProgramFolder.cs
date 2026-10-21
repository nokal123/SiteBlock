namespace SiteBlock.Service;

/// <summary>
/// Compares the program folder with its backup copy file by file and copies back every file that is missing or a different size.
/// The programs are published as many files (a small launcher .exe plus its .dll and the .NET runtime files beside it), so a
/// check of the .exe alone would miss a deleted or renamed .dll that stops a program from starting. ServiceGuard and AppGuard
/// both use it, because the daemon, the watchdog and the tray app all run from the same folder.
/// </summary>
internal static class ProgramFolder
{
    /// <summary>What one restore pass did.</summary>
    /// <param name="Restored">The paths, relative to the program folder, of the files that were copied back.</param>
    /// <param name="Failed">The relative paths of the files that differed but could not be copied back (a running program's files are locked on Windows).</param>
    /// <param name="BackupUnreadable">True when the backup folder could not be listed, so nothing was compared.</param>
    internal sealed record RestoreResult(IReadOnlyList<string> Restored, IReadOnlyList<string> Failed, bool BackupUnreadable);

    /// <summary>
    /// Copies every backup file whose twin in <paramref name="programDir"/> is missing or a different size, and leaves the rest
    /// alone, so a healthy folder costs one size read per file and no writes. Files in the program folder that the backup does
    /// not hold are ignored. <paramref name="isCancelled"/> is asked before each copy, so an uninstall that starts mid-pass stops it.
    /// Never throws.
    /// </summary>
    internal static RestoreResult Restore(string backupDir, string programDir, Func<bool>? isCancelled = null)
    {
        string[] files;
        try { files = Directory.GetFiles(backupDir, "*", SearchOption.AllDirectories); }
        catch (Exception) { return new RestoreResult([], [], BackupUnreadable: true); }

        var restored = new List<string>();
        var failed = new List<string>();
        foreach (var source in files)
        {
            if (isCancelled?.Invoke() == true) break;
            var relative = Path.GetRelativePath(backupDir, source);
            var destination = Path.Combine(programDir, relative);
            try
            {
                // Size is the cheap test for "deleted or replaced": a copy of the backup always has the backup's size.
                var current = new FileInfo(destination);
                if (current.Exists && current.Length == new FileInfo(source).Length) continue;
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                // The copy goes to a temporary name first and is then moved over the target in one step, so a program that starts mid-restore never loads a half-written file, and two guards restoring at once each finish a whole file.
                var temp = destination + ".siteblock-" + Path.GetRandomFileName();
                try
                {
                    File.Copy(source, temp, overwrite: true);
                    File.Move(temp, destination, overwrite: true);
                }
                finally
                {
                    try { if (File.Exists(temp)) File.Delete(temp); } catch { /* only cleanup */ }
                }
                restored.Add(relative);
            }
            // One file that cannot be copied (locked, access denied, a folder in its place) must not stop the others, so every failure is collected and the loop goes on.
            catch (Exception) { failed.Add(relative); }
        }
        return new RestoreResult(restored, failed, BackupUnreadable: false);
    }
}
