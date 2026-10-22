using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>
/// Makes the real hosts file hold exactly SiteBlock's managed section for the blocked host names, and takes over the file so a
/// user who freezes it cannot keep SiteBlock out. <see cref="HostsFileEditor"/> does all the text editing; this class reads the
/// file, repairs the DataBasePath redirect, clears the attributes and access list that could block a write, writes the new text
/// safely, flushes the DNS cache, and logs a tamper it did not expect. In sandbox mode and off Windows it only reads, renders and
/// writes the one sandbox file (see 06-windows.md § HostsEnforcer).
/// </summary>
public sealed class HostsEnforcer : IHostsEnforcer
{
    // A failure message that repeats is logged at most this often, so a problem that happens every tick (a read-only disk, say) does not fill the log.
    private const long RepeatedFailureLogIntervalMs = 60_000;
    // The value DataBasePath must hold; the already-expanded form (C:\Windows\...) is treated as equally correct.
    private const string WantedDataBasePath = @"%SystemRoot%\System32\drivers\etc";

    // The first of 128 placeholder characters (U+DC80 to U+DCFF) that stand for a byte that is not part of valid UTF-8. They are lone low surrogates, which decoding valid UTF-8 can never produce, so a placeholder can never be confused with a real character of the file.
    private const int StrayBytePlaceholderBase = 0xDC00;
    // The expanded form of the wanted DataBasePath (such as C:\Windows\System32\drivers\etc), computed once for comparing against a stored, already-expanded value.
    private static readonly string ExpandedWantedDataBasePath = Environment.ExpandEnvironmentVariables(WantedDataBasePath);

    // What reading the hosts file found.
    private enum ReadOutcome
    {
        /// The file was read.
        Read,
        /// No file is there, which counts as an empty file.
        Missing,
        /// A folder (or anything else that is not a file) sits at the hosts path.
        NotAFile,
        /// The access list refuses this process read access.
        Denied,
        /// The file exists but could not be read just now, for example because another program holds it open.
        Busy,
    }

    private readonly Paths _paths;
    private readonly Log _log;
    // When each failure message was last logged (from Environment.TickCount64), so the same message repeats at most once a minute while different messages are each still logged.
    private readonly Dictionary<string, long> _lastFailureLogged = new(StringComparer.Ordinal);

    /// <summary>Creates an enforcer for the hosts file named in the paths. In sandbox mode it never touches the registry, the file's access list or the DNS cache.</summary>
    public HostsEnforcer(Paths paths, Log log)
    {
        _paths = paths;
        _log = log;
    }

    // True on a real Windows install (not a sandbox run), the only case where the registry, the file's access list and the DNS cache are touched.
    [SupportedOSPlatformGuard("windows")]
    private bool IsProduction => !_paths.IsSandbox && OperatingSystem.IsWindows();

    /// <summary>
    /// Reads the hosts file, computes what it should contain for the blocked host names, and rewrites it when it differs. Returns
    /// true when the file is correct after the pass. <paramref name="causedByCommand"/> should be true when the caller just
    /// changed the block list on purpose, so the rewrite is expected and is not logged as tampering.
    /// </summary>
    public bool Enforce(IReadOnlyList<string> hosts, bool causedByCommand)
    {
        // Moving the file through the DataBasePath redirect must be undone like editing it, so this is checked first on every pass, whether or not the file itself can be read.
        if (IsProduction) RepairDataBasePath();

        var outcome = ReadCurrent(out string current);
        // An access list that denies SYSTEM read access is taken over, then the file is read again.
        if (outcome == ReadOutcome.Denied && IsProduction)
        {
            TakeOverFile(force: true);
            outcome = ReadCurrent(out current);
        }
        // Text that could not be read is never treated as empty: rewriting it would delete every line the person added themselves. The pass is skipped and the next one, 2 seconds later, tries again.
        if (outcome is ReadOutcome.Denied or ReadOutcome.Busy)
        {
            LogFailure("hosts file could not be read, so it was left unchanged this pass");
            return false;
        }

        string wanted = HostsFileEditor.Render(current, hosts);
        if (wanted == current)
        {
            // The file already holds exactly what it should.
            return true;
        }

        // A folder at the hosts path stops Windows reading any hosts file, so it is renamed out of the way (keeping whatever it holds) before the real file is written.
        if (outcome == ReadOutcome.NotAFile && !MoveAsideNonFile()) return false;

        // In production the file could be frozen by a read-only attribute or an access list that denies SYSTEM, so free it before writing.
        if (IsProduction) TakeOverFile(force: false);

        // Another program (or the person, in an editor) may have saved the file since it was read. Writing now would replace that save with text built from the
        // older copy and lose it, so the file is read once more and the pass stops when it changed; the next pass, 2 seconds later, starts from the new text.
        if (outcome is ReadOutcome.Read or ReadOutcome.Missing && (ReadCurrent(out string again) != outcome || again != current)) return false;

        if (!WriteAtomically(wanted)) return false;

        // A recently resolved blocked site could keep working from the DNS cache, so empty it once the file has changed.
        if (IsProduction) HostsNative.FlushDnsCache();

        // A rewrite nobody asked for means someone or another program changed the file, so it goes in the log.
        if (!causedByCommand) _log.Write(DescribeChange(current, wanted));
        return true;
    }

    // Reads the hosts file without losing any byte (see DecodeKeepingBytes) and says what it found. Only a missing file gives empty text with success; a folder, a refused read and a busy file are reported apart so the caller never mistakes them for an empty file. Never throws.
    private ReadOutcome ReadCurrent(out string text)
    {
        text = "";
        try
        {
            if (Directory.Exists(_paths.HostsFile)) return ReadOutcome.NotAFile;
            if (!File.Exists(_paths.HostsFile)) return ReadOutcome.Missing;
            byte[] bytes;
            // Sharing read, write and delete lets the read succeed while another program, such as an editor saving, has the file open.
            using (var stream = new FileStream(_paths.HostsFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var buffer = new MemoryStream())
            {
                stream.CopyTo(buffer);
                bytes = buffer.ToArray();
            }
            text = DecodeKeepingBytes(bytes);
            return ReadOutcome.Read;
        }
        catch (UnauthorizedAccessException)
        {
            return ReadOutcome.Denied;
        }
        catch
        {
            return ReadOutcome.Busy;
        }
    }

    // Renames a folder that sits at the hosts path to "hosts.siteblock-moved-<random>" beside it, so the real file can be written and nothing in the folder is lost. Returns false, after a rate-limited log line, when the rename fails.
    private bool MoveAsideNonFile()
    {
        string movedTo = _paths.HostsFile + ".siteblock-moved-" + Path.GetRandomFileName();
        try
        {
            Directory.Move(_paths.HostsFile, movedTo);
            _log.Write("a folder in place of the hosts file was moved aside");
            return true;
        }
        catch (Exception error)
        {
            LogFailure($"cannot move aside the folder in place of the hosts file: {Describe(error)}");
            return false;
        }
    }

    // Reads the DataBasePath registry value and resets it to the wanted location when Windows would read the hosts file from anywhere else, then empties the DNS cache so names looked up from the wrong file are forgotten. A missing value means Windows uses its built-in default, which is the wanted location, so it is left alone.
    [SupportedOSPlatform("windows")]
    private void RepairDataBasePath()
    {
        try
        {
            var stored = HostsNative.ReadDataBasePath();
            if (stored is null) return;
            // Windows only expands %SystemRoot% in a value of the expandable-string type. A plain-string value holding the literal text "%SystemRoot%\..." names a folder that does not exist, so the comparison uses what Windows would actually read.
            string effective = stored.Value.Type == HostsNative.RegExpandSz ? Environment.ExpandEnvironmentVariables(stored.Value.Text) : stored.Value.Text;
            if (string.Equals(effective.TrimEnd('\\'), ExpandedWantedDataBasePath.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return;
            if (HostsNative.WriteDataBasePath(WantedDataBasePath))
            {
                _log.Write("hosts file location repaired");
                HostsNative.FlushDnsCache();
            }
            else LogFailure("cannot reset the hosts file location in the registry");
        }
        catch (Exception error)
        {
            // A registry failure here must never stop the file itself from being enforced.
            LogFailure($"cannot check the hosts file location in the registry: {Describe(error)}");
        }
    }

    // Frees the hosts file for writing: clears the read-only, hidden and system attributes and, when SYSTEM has been locked out (or `force` says a read was refused), takes ownership and resets the access list, then clears the attributes again with the owner's rights. A failure fails open: it is logged (rate-limited) and the write is still attempted.
    [SupportedOSPlatform("windows")]
    private void TakeOverFile(bool force)
    {
        bool lockedOut = force;
        try { HostsNative.ClearBlockingAttributes(_paths.HostsFile); }
        // Changing attributes needs write-attributes access, so a refusal here is itself a sign the access list locks SYSTEM out.
        catch (UnauthorizedAccessException) { lockedOut = true; }
        catch (Exception error) { LogFailure($"cannot clear the hosts file attributes: {Describe(error)}"); }

        try
        {
            // With the attributes cleared, a refusal to open the file for writing means the access list, not the read-only bit, denies SYSTEM.
            if (!lockedOut && HostsNative.CanWrite(_paths.HostsFile)) return;
            string? failure = HostsNative.ResetSecurity(_paths.HostsFile);
            if (failure is not null)
            {
                LogFailure($"cannot reset the hosts file access list: {failure}");
                return;
            }
            _log.Write("hosts file access list repaired");
            // SYSTEM can now change the attributes it could not touch before the takeover.
            HostsNative.ClearBlockingAttributes(_paths.HostsFile);
        }
        catch (Exception error)
        {
            LogFailure($"cannot reset the hosts file access list: {Describe(error)}");
        }
    }

    // Writes the text to a randomly named temp file in the hosts file's own folder and moves it over the hosts file, so a reader always sees the whole old or whole new file. A failed move falls back to writing the hosts file in place; only when that also fails does it log and return false.
    private bool WriteAtomically(string wanted)
    {
        string folder = Path.GetDirectoryName(_paths.HostsFile) ?? ".";
        // A random name means a file or folder planted at a fixed temp path cannot block the write.
        string temp = Path.Combine(folder, "siteblock-" + Path.GetRandomFileName());
        byte[] bytes = EncodeKeepingBytes(wanted);
        try
        {
            File.WriteAllBytes(temp, bytes);
            // overwrite replaces the hosts file in one step; after it succeeds the temp file is already gone.
            File.Move(temp, _paths.HostsFile, overwrite: true);
            return true;
        }
        catch (Exception moveError)
        {
            try
            {
                // The move can fail where writing the file in place still works (for example a folder that refuses to replace a file), so try that before giving up.
                File.WriteAllBytes(_paths.HostsFile, bytes);
                TryDelete(temp);
                return true;
            }
            catch (Exception inPlaceError)
            {
                TryDelete(temp);
                LogFailure($"hosts file could not be updated: {Describe(moveError)}; writing in place also failed: {Describe(inPlaceError)}");
                return false;
            }
        }
    }

    // Deletes a leftover temp file, ignoring any error, because it is only cleanup.
    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }

    /// <summary>
    /// Picks the log message for a rewrite that no command caused. It is "blocks removed from hosts file" only when the pass did
    /// nothing but take managed lines away (the block list is now empty or shorter). Any other change — block lines put back, a
    /// bypass line in the user's own lines removed, or a section moved — is "hosts file repaired".
    /// </summary>
    internal static string DescribeChange(string current, string wanted)
    {
        string[] currentLines = current.Split('\n');
        string[] wantedLines = wanted.Split('\n');
        var currentSet = new HashSet<string>(currentLines, StringComparer.Ordinal);

        // A line the new text has that the old text did not means block lines were put back, or a user line was rewritten after a blocked name was cut out of it.
        if (wantedLines.Any(line => !currentSet.Contains(line))) return "hosts file repaired";

        // With every managed section removed from both texts, any remaining difference is in the user's own lines, so a bypass line was removed.
        if (HostsFileEditor.Render(current, []) != HostsFileEditor.Render(wanted, [])) return "hosts file repaired";

        // Nothing was added and the user's own lines are unchanged. If a line the old text had is now gone, managed lines were removed; otherwise only the layout changed.
        var wantedSet = new HashSet<string>(wantedLines, StringComparer.Ordinal);
        bool removedSomething = !currentSet.IsSubsetOf(wantedSet);
        return removedSomething ? "blocks removed from hosts file" : "hosts file repaired";
    }

    /// <summary>
    /// Turns the file's bytes into text without losing any of them. Every valid UTF-8 sequence becomes its character, so
    /// SiteBlock's own lines (whose BEGIN marker holds an em dash) always read back as written. Each byte that is not part
    /// of valid UTF-8, such as an accented letter in a comment saved in an older single-byte encoding, becomes its own
    /// placeholder character (U+DC00 plus the byte), which <see cref="EncodeKeepingBytes"/> turns back into that exact byte.
    /// A file of valid UTF-8 decodes exactly as an ordinary UTF-8 read would.
    /// </summary>
    internal static string DecodeKeepingBytes(byte[] bytes)
    {
        var text = new StringBuilder(bytes.Length);
        var rest = bytes.AsSpan();
        while (!rest.IsEmpty)
        {
            if (Rune.DecodeFromUtf8(rest, out Rune rune, out int used) == System.Buffers.OperationStatus.Done)
            {
                text.Append(rune.ToString());
                rest = rest[used..];
            }
            else
            {
                // Only bytes from 0x80 up can fail to decode, because every byte below 0x80 is a valid one-byte character; one stray byte is kept and decoding starts again after it.
                text.Append((char)(StrayBytePlaceholderBase + rest[0]));
                rest = rest[1..];
            }
        }
        return text.ToString();
    }

    /// <summary>
    /// Turns text back into bytes, the reverse of <see cref="DecodeKeepingBytes"/>: each placeholder character becomes the byte
    /// it stands for, and everything else is written as UTF-8. Any other lone surrogate (which no decode produces) is written
    /// as the UTF-8 replacement character, so the result is never invalid in a new way.
    /// </summary>
    internal static byte[] EncodeKeepingBytes(string text)
    {
        var bytes = new List<byte>(text.Length);
        Span<byte> utf8 = stackalloc byte[4];
        var rest = text.AsSpan();
        while (!rest.IsEmpty)
        {
            if (Rune.DecodeFromUtf16(rest, out Rune rune, out int used) == System.Buffers.OperationStatus.Done)
            {
                int length = rune.EncodeToUtf8(utf8);
                for (int i = 0; i < length; i++) bytes.Add(utf8[i]);
                rest = rest[used..];
                continue;
            }
            char lone = rest[0];
            if (lone >= StrayBytePlaceholderBase + 0x80 && lone <= StrayBytePlaceholderBase + 0xFF) bytes.Add((byte)(lone - StrayBytePlaceholderBase));
            else bytes.AddRange("�"u8.ToArray());
            rest = rest[1..];
        }
        return [.. bytes];
    }

    // Names an error by its type and code (such as "IOException 0x80070020") without its message text. .NET's messages include file paths, and the temp file's path is random, so the message would differ every pass and slip past the once-a-minute limit.
    private static string Describe(Exception error) => $"{error.GetType().Name} 0x{error.HResult:X8}";

    // Logs a failure message, unless the same message was already logged within the last minute. Each message is timed on its own, so a pass that fails in three ways logs three lines once a minute rather than on every pass. Never names a host, a domain or a password; only file paths and system error text appear.
    private void LogFailure(string message)
    {
        long now = Environment.TickCount64;
        if (_lastFailureLogged.TryGetValue(message, out long last) && now - last < RepeatedFailureLogIntervalMs) return;
        _lastFailureLogged[message] = now;
        _log.Write(message);
    }
}

/// <summary>
/// The Windows-only system calls the hosts enforcer needs: reading and resetting the DataBasePath registry value, clearing the
/// file attributes that freeze a file, testing and repairing the file's access list, and flushing the DNS cache. Every call is
/// raw P/Invoke so the Service library needs no extra package, and every interop name is prefixed "Hosts" so it cannot clash.
/// </summary>
[SupportedOSPlatform("windows")]
internal static class HostsNative
{
    // The Windows default access list for the hosts file in SDDL form: SYSTEM (SY) and Administrators (BA) get full access (FA); Users (BU), all Store apps (AC, ALL APPLICATION PACKAGES) and all restricted Store apps (S-1-15-2-2) get read & execute (0x1200a9). The two app-package entries let sandboxed programs, such as a browser's network process, read the file as they do on a fresh Windows install.
    private const string DefaultHostsSddl = "D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)(A;;0x1200a9;;;AC)(A;;0x1200a9;;;S-1-15-2-2)";
    // The registry subkey of HKEY_LOCAL_MACHINE that holds the resolver's DataBasePath value.
    private const string TcpipParametersSubkey = @"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters";
    private const string DataBasePathValueName = "DataBasePath";

    private const uint KeyQueryValue = 0x0001;
    private const uint KeySetValue = 0x0002;
    private const uint KeyWow6464Key = 0x0100;
    /// The registry type code of an expandable string (REG_EXPAND_SZ), whose %SystemRoot% Windows replaces with the real folder when it reads the value.
    internal const uint RegExpandSz = 2;
    // The predefined HKEY_LOCAL_MACHINE handle: 0x80000002 as a signed 32-bit value, sign-extended to the full native width, which is how Windows defines it.
    private static readonly nint HkeyLocalMachine = unchecked((nint)(int)0x80000002);

    // Reads the DataBasePath value under the Tcpip Parameters key with its registry type code, or null when the key or value is missing or unreadable.
    internal static (string Text, uint Type)? ReadDataBasePath()
    {
        if (RegOpenKeyExW(HkeyLocalMachine, TcpipParametersSubkey, 0, KeyQueryValue | KeyWow6464Key, out nint key) != 0) return null;
        try
        {
            uint size = 0;
            // The first call learns the size the value needs; the data pointer is null for it.
            if (RegQueryValueExW(key, DataBasePathValueName, 0, out _, null, ref size) != 0 || size == 0) return null;
            byte[] buffer = new byte[size];
            if (RegQueryValueExW(key, DataBasePathValueName, 0, out uint type, buffer, ref size) != 0) return null;
            // The value is a null-terminated UTF-16 string; decode it and cut it at the first null. A value of another type decodes to text that matches no folder, which the caller then repairs.
            string text = Encoding.Unicode.GetString(buffer, 0, (int)size);
            int nul = text.IndexOf('\0');
            return (nul >= 0 ? text[..nul] : text, type);
        }
        finally
        {
            RegCloseKey(key);
        }
    }

    // Writes the DataBasePath value as a REG_EXPAND_SZ string and returns whether it was written.
    internal static bool WriteDataBasePath(string value)
    {
        if (RegOpenKeyExW(HkeyLocalMachine, TcpipParametersSubkey, 0, KeySetValue | KeyWow6464Key, out nint key) != 0) return false;
        try
        {
            // A REG_EXPAND_SZ value is stored as a null-terminated UTF-16 string.
            byte[] data = Encoding.Unicode.GetBytes(value + "\0");
            return RegSetValueExW(key, DataBasePathValueName, 0, RegExpandSz, data, (uint)data.Length) == 0;
        }
        finally
        {
            RegCloseKey(key);
        }
    }

    // Clears the read-only, hidden and system attributes on the file when any is set. A file that is not there yet has nothing to clear.
    internal static void ClearBlockingAttributes(string path)
    {
        if (!File.Exists(path)) return;
        FileAttributes attributes = File.GetAttributes(path);
        FileAttributes cleared = attributes & ~(FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System);
        // Only write the attributes back when one of the three was actually set, to avoid a pointless change.
        if (cleared != attributes) File.SetAttributes(path, cleared);
    }

    // Tests whether this process (SYSTEM in production) may write the file. A file that is not there yet counts as writable, because the folder, not the file, governs creating it, and SYSTEM may create files there.
    internal static bool CanWrite(string path)
    {
        if (!File.Exists(path)) return true;
        try
        {
            // Opening for write without truncating leaves the content untouched; a refusal means the access list denies SYSTEM write access.
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite);
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
        catch
        {
            // Any other failure (the file is locked, say) is left for the write step to handle; it is not a reason to take ownership.
            return true;
        }
    }

    // Takes ownership of the file and resets its access list to the Windows default, so a person who removed SYSTEM's access cannot keep the file frozen. Returns null on success, or a short description of what failed.
    internal static string? ResetSecurity(string path) => OwnershipNative.TakeOwnershipAndSetAcl(path, DefaultHostsSddl);

    // Empties the Windows DNS Client cache; any failure is ignored, because clearing the cache must never stop enforcement.
    internal static void FlushDnsCache()
    {
        try { DnsFlushResolverCache(); }
        catch { }
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegOpenKeyExW(nint hKey, string subKey, uint options, uint samDesired, out nint result);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegQueryValueExW(nint hKey, string valueName, nint reserved, out uint type, [Out] byte[]? data, ref uint dataSize);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegSetValueExW(nint hKey, string valueName, uint reserved, uint type, byte[] data, uint dataSize);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int RegCloseKey(nint hKey);

    [DllImport("dnsapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DnsFlushResolverCache();
}
