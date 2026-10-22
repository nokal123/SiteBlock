using System.Text;
using SiteBlock.Integration.Tests.Support;
using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// SharedFile.ReadAllText reads a whole file while letting other programs keep reading, writing, renaming or deleting it. Expected values come from 06-windows.md
// § SiteBlock.Core (State file reads and writes: files are read "while letting other programs read, write, rename or delete them") and § ServiceGuard and the watchdog
// (a read that lacks delete sharing makes the daemon's save, which moves a new file over the old one, fail).
//
// Windows decides sharing both ways: a new handle is refused when it does not share what an open handle already has, and when an open handle does not share what the new
// one asks for. So "SharedFile's open never blocks a delete or rename" is the same check as "SharedFile can open a file another handle holds with delete access", which a
// test can set up without any timing. Each Windows test carries a control that an ordinary File.ReadAllText is refused in the same situation, which shows the situation
// really tests sharing. On macOS and Linux files have no sharing modes, so those tests are skipped there.
public sealed class SharedFileTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "sbshared-" + Guid.NewGuid().ToString("N"));
    private readonly string _path;
    private const string Text = "{\"blocked\":[\"reddit.com\"],\"note\":\"é—ü\"}\n";

    public SharedFileTests()
    {
        Directory.CreateDirectory(_folder);
        _path = Path.Combine(_folder, "state.json");
        File.WriteAllText(_path, Text, new UTF8Encoding(false));
    }

    public void Dispose()
    {
        try { Directory.Delete(_folder, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    [Fact]
    public void ReadAllText_WhileAnotherProgramHasTheFileOpenForWriting_ReadsTheWholeText()
    {
        // An editor keeps its own handle open for writing and lets others read and write.
        using var writer = new FileStream(_path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);

        Assert.Equal(Text, SharedFile.ReadAllText(_path));
    }

    [WindowsFact("Windows sharing modes decide whether an open handle blocks another; macOS and Linux have none")]
    public void ReadAllText_WhileAWriterThatSharesReadingAndWritingHasItOpen_ReadsWhereAnOrdinaryReadIsRefused()
    {
        using var writer = new FileStream(_path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite);

        // Control: an ordinary read asks the writer to share only reading, which a handle already writing cannot accept.
        Assert.Throws<IOException>(() => File.ReadAllText(_path));
        Assert.Equal(Text, SharedFile.ReadAllText(_path));
    }

    [WindowsFact("Windows sharing modes decide whether an open handle blocks a delete or rename; macOS and Linux have none")]
    public void ReadAllText_WhileAnotherHandleHoldsDeleteAccess_ReadsWhereAnOrdinaryReadIsRefused()
    {
        // A handle opened to delete the file when it closes holds delete access, the access a delete or a rename (a save that moves a new file over this one) needs.
        using var deleter = new FileStream(_path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.DeleteOnClose);

        // Control: an ordinary read does not share delete access, so it is refused while that handle is open; by the same rule it would block a delete while it reads.
        Assert.Throws<IOException>(() => File.ReadAllText(_path));
        Assert.Equal(Text, SharedFile.ReadAllText(_path));
    }

    [WindowsFact("deleting and renaming a file another handle has open depends on Windows sharing modes")]
    public void ReadAllText_HandleIsClosedAfterReading_SoAnExclusiveOpenRenameAndDeleteSucceedAtOnce()
    {
        // Control: while a handle that shares everything is open, an open that shares nothing is refused, so the exclusive open below really detects a leaked handle.
        using (new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            Assert.Throws<IOException>(() => new FileStream(_path, FileMode.Open, FileAccess.ReadWrite, FileShare.None).Dispose());
        }

        Assert.Equal(Text, SharedFile.ReadAllText(_path));

        // An open that shares nothing (FileShare.None) is refused while any other handle to the file is open, even one that shares read, write and delete, so this
        // succeeds only when SharedFile closed its handle. The rename and delete below alone would pass with a leaked handle that shares delete.
        using (var exclusive = new FileStream(_path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Assert.Equal(Encoding.UTF8.GetByteCount(Text), exclusive.Length);
        }

        // Nothing stays open after the read: the file can be replaced by a rename and then deleted straight away.
        string replacement = Path.Combine(_folder, "state.json.tmp");
        File.WriteAllText(replacement, "{}");
        File.Move(replacement, _path, overwrite: true);
        File.Delete(_path);
        Assert.False(File.Exists(_path));
    }
}
