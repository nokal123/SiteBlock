using System.Text;
using SiteBlock.Core;
using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// Expected values come from 06-windows.md § HostsEnforcer and the macOS HostsEnforcer it mirrors, with HostsFileEditor.Render (the spec'd renderer) as the oracle for the file's wanted text.
public sealed class HostsEnforcerTests
{
    private static readonly DateTime OldStamp = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void Enforce_BlockOneSite_WritesExactlyTheManagedSection()
    {
        using var s = new TempSandbox();
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool ok = enforcer.Enforce(["reddit.com"], causedByCommand: true);

        // Derived by hand from the hosts-file rules in the design: a leading blank line, the BEGIN marker, the IPv4 and IPv6 lines, the END marker, each ending in "\n".
        string expected = "\n" + HostsFileEditor.BeginMarker + "\n0.0.0.0 reddit.com\n:: reddit.com\n" + HostsFileEditor.EndMarker + "\n";
        Assert.True(ok);
        Assert.Equal(expected, File.ReadAllText(s.Paths.HostsFile));
        // And the bytes carry no UTF-8 byte-order mark and no CR line endings.
        byte[] bytes = File.ReadAllBytes(s.Paths.HostsFile);
        Assert.Equal(Encoding.UTF8.GetBytes(expected), bytes);
        Assert.DoesNotContain((byte)'\r', bytes);
    }

    [Fact]
    public void Enforce_FileAlreadyCompliant_ReturnsTrueAndDoesNotRewrite()
    {
        using var s = new TempSandbox();
        string compliant = HostsFileEditor.Render("127.0.0.1 localhost\n", ["reddit.com"]);
        File.WriteAllText(s.Paths.HostsFile, compliant);
        File.SetLastWriteTimeUtc(s.Paths.HostsFile, OldStamp);
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool ok = enforcer.Enforce(["reddit.com"], causedByCommand: false);

        Assert.True(ok);
        // A rewrite moves a fresh temp file over the hosts file, which would change its timestamp; an untouched file keeps the stamp we set.
        Assert.Equal(OldStamp, File.GetLastWriteTimeUtc(s.Paths.HostsFile));
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void Enforce_ManagedSectionDeleted_RewritesAndLogsRepaired()
    {
        using var s = new TempSandbox();
        string tampered = "127.0.0.1 localhost\n";
        File.WriteAllText(s.Paths.HostsFile, tampered);
        File.SetLastWriteTimeUtc(s.Paths.HostsFile, OldStamp);
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool ok = enforcer.Enforce(["reddit.com"], causedByCommand: false);

        Assert.True(ok);
        Assert.Equal(HostsFileEditor.Render(tampered, ["reddit.com"]), File.ReadAllText(s.Paths.HostsFile));
        Assert.True(File.GetLastWriteTimeUtc(s.Paths.HostsFile) > OldStamp);
        // Block lines were put back, which the Mac rule calls a repair, not a removal.
        Assert.Equal(["hosts file repaired"], s.LogMessages());
    }

    [Fact]
    public void Enforce_BypassLineAdded_RemovesItAndLogsRepaired()
    {
        using var s = new TempSandbox();
        // A user line that points a blocked name at a real address, with a correct section already below it.
        string tampered = "1.2.3.4 blocked.example\n" + HostsFileEditor.Render("", ["blocked.example"]);
        File.WriteAllText(s.Paths.HostsFile, tampered);
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool ok = enforcer.Enforce(["blocked.example"], causedByCommand: false);

        Assert.True(ok);
        string wanted = HostsFileEditor.Render(tampered, ["blocked.example"]);
        Assert.Equal(wanted, File.ReadAllText(s.Paths.HostsFile));
        // The bypass line is gone from the written file.
        Assert.DoesNotContain("1.2.3.4", File.ReadAllText(s.Paths.HostsFile));
        Assert.Equal(["hosts file repaired"], s.LogMessages());
    }

    [Fact]
    public void Enforce_CausedByCommand_RewritesWithoutLogging()
    {
        using var s = new TempSandbox();
        string tampered = "127.0.0.1 localhost\n";
        File.WriteAllText(s.Paths.HostsFile, tampered);
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool ok = enforcer.Enforce(["reddit.com"], causedByCommand: true);

        Assert.True(ok);
        Assert.Equal(HostsFileEditor.Render(tampered, ["reddit.com"]), File.ReadAllText(s.Paths.HostsFile));
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void Enforce_MissingFile_WritesARealFile()
    {
        using var s = new TempSandbox();
        Assert.False(File.Exists(s.Paths.HostsFile));
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool ok = enforcer.Enforce(["reddit.com"], causedByCommand: true);

        Assert.True(ok);
        Assert.True(File.Exists(s.Paths.HostsFile));
        Assert.Equal(HostsFileEditor.Render("", ["reddit.com"]), File.ReadAllText(s.Paths.HostsFile));
    }

    [Fact]
    public void Enforce_MissingFileAndNothingToBlock_ReturnsTrueAndWritesNothing()
    {
        using var s = new TempSandbox();
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool ok = enforcer.Enforce([], causedByCommand: true);

        Assert.True(ok);
        Assert.False(File.Exists(s.Paths.HostsFile));
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void Enforce_FolderAtHostsPath_MovesItAsideAndWritesTheFile()
    {
        using var s = new TempSandbox();
        // 06-windows.md § HostsEnforcer step 3: a folder at the hosts path is renamed to hosts.siteblock-moved-<random> and the file is then written.
        Directory.CreateDirectory(s.Paths.HostsFile);
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool ok = enforcer.Enforce(["reddit.com"], causedByCommand: true);

        Assert.True(ok);
        Assert.True(File.Exists(s.Paths.HostsFile));
        Assert.False(Directory.Exists(s.Paths.HostsFile));
        Assert.Equal(HostsFileEditor.Render("", ["reddit.com"]), File.ReadAllText(s.Paths.HostsFile));
        // The folder was kept, renamed beside the hosts file.
        string folder = Path.GetDirectoryName(s.Paths.HostsFile)!;
        Assert.Contains(Directory.GetDirectories(folder), d => Path.GetFileName(d).StartsWith("hosts.siteblock-moved-", StringComparison.Ordinal));
        Assert.Equal(["a folder in place of the hosts file was moved aside"], s.LogMessages());
    }

    [Fact]
    public void Enforce_UnreadableFile_LeavesItUnchangedAndLogsOncePerMinute()
    {
        using var s = new TempSandbox();
        // 06-windows.md § HostsEnforcer step 2: a file that cannot be read is left unchanged for the pass; the pass returns false and logs once a minute. Only a truly missing file counts as empty.
        string original = HostsFileEditor.Render("127.0.0.1 localhost\n", ["reddit.com"]);
        // The block list differs from what the file holds, so a readable file would be rewritten; the point is that an unreadable one is not.
        File.WriteAllText(s.Paths.HostsFile, original);
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool first;
        bool second;
        if (OperatingSystem.IsWindows())
        {
            // On Windows an exclusive hold makes the enforcer's shared read fail (busy).
            using var hold = new FileStream(s.Paths.HostsFile, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            first = enforcer.Enforce(["example.com"], causedByCommand: false);
            second = enforcer.Enforce(["example.com"], causedByCommand: false);
        }
        else
        {
            // On Unix removing the owner's read permission makes the read fail with access denied.
            File.SetUnixFileMode(s.Paths.HostsFile, UnixFileMode.None);
            first = enforcer.Enforce(["example.com"], causedByCommand: false);
            second = enforcer.Enforce(["example.com"], causedByCommand: false);
            File.SetUnixFileMode(s.Paths.HostsFile, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }

        Assert.False(first);
        Assert.False(second);
        // The file still holds exactly what it did: nothing was written over it.
        Assert.Equal(original, File.ReadAllText(s.Paths.HostsFile));
        Assert.Equal(["hosts file could not be read, so it was left unchanged this pass"], s.LogMessages());
    }

    [Fact]
    public void Enforce_InvalidUtf8UserLine_KeepsThePersonsOwnBytes()
    {
        using var s = new TempSandbox();
        // A comment line saved in a single-byte encoding: 0xE9 (é in Latin-1) is not valid UTF-8, so the file is read as Latin-1.
        // 06-windows.md § HostsEnforcer step 2 promises the person's own lines go back byte for byte.
        byte[] userBytes = Encoding.Latin1.GetBytes("# note é\n127.0.0.1 localhost\n");
        File.WriteAllBytes(s.Paths.HostsFile, userBytes);
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        bool ok = enforcer.Enforce(["reddit.com"], causedByCommand: true);

        Assert.True(ok);
        byte[] written = File.ReadAllBytes(s.Paths.HostsFile);
        // The raw 0xE9 byte survives unchanged (not turned into the UTF-8 replacement character or a '?').
        Assert.Contains((byte)0xE9, written);
        // Latin-1 round-trips every byte, so decoding it back shows the person's comment line exactly, and a managed section for the blocked site.
        string decoded = Encoding.Latin1.GetString(written);
        Assert.Contains("# note é", decoded);
        Assert.Contains("0.0.0.0 reddit.com", decoded);
    }

    // Regression guard for the fixed em-dash/encoding bug. A hosts file holding an invalid-UTF-8 byte must reach a stable,
    // idempotent state: the person's stray byte is kept exactly, and SiteBlock's own BEGIN marker (which holds an em-dash) is
    // stored as UTF-8, so the second pass finds the file already compliant and changes nothing. (06-windows.md § HostsEnforcer step 2.)
    [Fact]
    public void Enforce_InvalidUtf8File_IsIdempotentAndKeepsTheManagedSectionIntact()
    {
        using var s = new TempSandbox();
        // "# caf" is 5 bytes, so the stray 0xE9 (é in a single-byte encoding) sits at index 5.
        byte[] seed = [.. Encoding.ASCII.GetBytes("# caf"), 0xE9, .. Encoding.ASCII.GetBytes("\n127.0.0.1 mydev.local\n")];
        File.WriteAllBytes(s.Paths.HostsFile, seed);
        var enforcer = new HostsEnforcer(s.Paths, s.Log);

        // Pass 1: a change nobody asked for puts the block section in and logs a single repair line.
        bool first = enforcer.Enforce(["reddit.com"], causedByCommand: false);
        byte[] afterFirst = File.ReadAllBytes(s.Paths.HostsFile);
        // Pass 2: the file is already correct, so it is untouched and nothing is logged.
        bool second = enforcer.Enforce(["reddit.com"], causedByCommand: false);
        byte[] afterSecond = File.ReadAllBytes(s.Paths.HostsFile);

        Assert.True(first);
        Assert.True(second);
        Assert.Equal(afterFirst, afterSecond);
        Assert.Equal(["hosts file repaired"], s.LogMessages());
        // The person's stray byte is kept exactly, at its original offset.
        Assert.Equal(0xE9, afterSecond[5]);
        // The BEGIN marker's em-dash is stored as its UTF-8 bytes E2 80 94, not corrupted or replaced.
        Assert.True(ContainsSequence(afterSecond, [0xE2, 0x80, 0x94]));
    }

    [Fact]
    public void Enforce_ShrinkingBlockList_LogsBlocksRemoved()
    {
        using var s = new TempSandbox();
        var enforcer = new HostsEnforcer(s.Paths, s.Log);
        // Start with two sites blocked (the set-up is an intended change, so it is not logged).
        enforcer.Enforce(["a.example", "b.example"], causedByCommand: true);

        // One site drops off the list; nobody asked, so the managed-lines-only removal is logged as "blocks removed from hosts file".
        bool ok = enforcer.Enforce(["a.example"], causedByCommand: false);

        Assert.True(ok);
        Assert.Equal(["blocks removed from hosts file"], s.LogMessages());
        string text = File.ReadAllText(s.Paths.HostsFile);
        Assert.Contains("0.0.0.0 a.example", text);
        Assert.DoesNotContain("b.example", text);
    }

    // True when needle appears as a contiguous run of bytes inside haystack.
    private static bool ContainsSequence(byte[] haystack, byte[] needle)
    {
        for (int i = 0; i + needle.Length <= haystack.Length; i++)
        {
            bool match = true;
            for (int j = 0; j < needle.Length; j++)
                if (haystack[i + j] != needle[j]) { match = false; break; }
            if (match) return true;
        }
        return false;
    }

    [Theory]
    [MemberData(nameof(DescribeChangeCases))]
    public void DescribeChange_PicksTheMessageTheMacRuleWould(string current, string wanted, string expected)
    {
        Assert.Equal(expected, HostsEnforcer.DescribeChange(current, wanted));
    }

    public static TheoryData<string, string, string> DescribeChangeCases()
    {
        var data = new TheoryData<string, string, string>();
        string userLine = "1.1.1.1 keep.example\n";

        // Block lines put back (the new text has lines the old text lacked): the Mac rule calls this a repair.
        data.Add(HostsFileEditor.Render(userLine, []), HostsFileEditor.Render(userLine, ["reddit.com"]), "hosts file repaired");

        // The pass did nothing but take managed lines away (the section removed, nothing added, the user's lines unchanged): the Mac rule calls this a removal.
        data.Add(HostsFileEditor.Render(userLine, ["reddit.com"]), HostsFileEditor.Render(userLine, []), "blocks removed from hosts file");

        // A bypass line in the user's own lines was removed while the section stayed: the Mac rule calls this a repair.
        string withBypass = "1.2.3.4 reddit.com\n" + HostsFileEditor.Render("", ["reddit.com"]);
        data.Add(withBypass, HostsFileEditor.Render(withBypass, ["reddit.com"]), "hosts file repaired");

        return data;
    }
}
