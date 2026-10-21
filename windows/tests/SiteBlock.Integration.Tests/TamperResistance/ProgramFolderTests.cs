using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// ProgramFolder.Restore compares a program folder with its backup file by file and copies back what differs. It is file logic with no Windows calls, so it runs on the Mac.
// Expected values come from 06-windows.md § ServiceGuard ("Program files"): compare every backup file by size, copy back each missing or different one, leave extras alone.
public sealed class ProgramFolderTests
{
    private static string Dir(TempSandbox s, string name)
    {
        string path = Path.Combine(s.Root, name);
        Directory.CreateDirectory(path);
        return path;
    }

    [Fact]
    public void Restore_BackupFolderMissing_ReportsUnreadable()
    {
        using var s = new TempSandbox();
        string program = Dir(s, "program");

        var result = ProgramFolder.Restore(Path.Combine(s.Root, "no-such-backup"), program);

        Assert.True(result.BackupUnreadable);
        Assert.Empty(result.Restored);
        Assert.Empty(result.Failed);
    }

    [Fact]
    public void Restore_SameSizeFiles_CopiesNothing()
    {
        using var s = new TempSandbox();
        string backup = Dir(s, "backup");
        string program = Dir(s, "program");
        File.WriteAllBytes(Path.Combine(backup, "a.bin"), [1, 2, 3]);
        // Same length, different content: a copy would change the bytes, so unchanged bytes prove no copy happened.
        File.WriteAllBytes(Path.Combine(program, "a.bin"), [9, 9, 9]);

        var result = ProgramFolder.Restore(backup, program);

        Assert.False(result.BackupUnreadable);
        Assert.Empty(result.Restored);
        Assert.Empty(result.Failed);
        Assert.Equal(new byte[] { 9, 9, 9 }, File.ReadAllBytes(Path.Combine(program, "a.bin")));
    }

    [Fact]
    public void Restore_MissingFiles_CopiesThemIncludingNestedOnes()
    {
        using var s = new TempSandbox();
        string backup = Dir(s, "backup");
        string program = Dir(s, "program");
        File.WriteAllBytes(Path.Combine(backup, "a.bin"), [1, 2]);
        Directory.CreateDirectory(Path.Combine(backup, "sub"));
        File.WriteAllBytes(Path.Combine(backup, "sub", "b.bin"), [3, 4, 5]);

        var result = ProgramFolder.Restore(backup, program);

        Assert.Contains("a.bin", result.Restored);
        Assert.Contains(Path.Combine("sub", "b.bin"), result.Restored);
        Assert.Empty(result.Failed);
        Assert.Equal(new byte[] { 1, 2 }, File.ReadAllBytes(Path.Combine(program, "a.bin")));
        Assert.Equal(new byte[] { 3, 4, 5 }, File.ReadAllBytes(Path.Combine(program, "sub", "b.bin")));
    }

    [Fact]
    public void Restore_DifferentSize_CopiesTheFile()
    {
        using var s = new TempSandbox();
        string backup = Dir(s, "backup");
        string program = Dir(s, "program");
        File.WriteAllBytes(Path.Combine(backup, "a.bin"), [1, 2, 3, 4]);
        File.WriteAllBytes(Path.Combine(program, "a.bin"), [0]);

        var result = ProgramFolder.Restore(backup, program);

        Assert.Equal(["a.bin"], result.Restored);
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, File.ReadAllBytes(Path.Combine(program, "a.bin")));
    }

    [Fact]
    public void Restore_ExtraProgramFileNotInBackup_IsLeftAlone()
    {
        using var s = new TempSandbox();
        string backup = Dir(s, "backup");
        string program = Dir(s, "program");
        File.WriteAllBytes(Path.Combine(backup, "a.bin"), [1]);
        File.WriteAllBytes(Path.Combine(program, "a.bin"), [1]);
        File.WriteAllBytes(Path.Combine(program, "extra.bin"), [7, 7]);

        var result = ProgramFolder.Restore(backup, program);

        Assert.Empty(result.Restored);
        Assert.True(File.Exists(Path.Combine(program, "extra.bin")));
    }

    [Fact]
    public void Restore_Cancelled_CopiesNothing()
    {
        using var s = new TempSandbox();
        string backup = Dir(s, "backup");
        string program = Dir(s, "program");
        File.WriteAllBytes(Path.Combine(backup, "a.bin"), [1, 2]);

        var result = ProgramFolder.Restore(backup, program, () => true);

        Assert.Empty(result.Restored);
        Assert.False(File.Exists(Path.Combine(program, "a.bin")));
    }

    [Fact]
    public void Restore_DestinationIsADirectory_RecordsFailure()
    {
        using var s = new TempSandbox();
        string backup = Dir(s, "backup");
        string program = Dir(s, "program");
        File.WriteAllBytes(Path.Combine(backup, "a.bin"), [1, 2]);
        // A directory sitting where the file should go cannot be overwritten by a file.
        Directory.CreateDirectory(Path.Combine(program, "a.bin"));

        var result = ProgramFolder.Restore(backup, program);

        Assert.Equal(["a.bin"], result.Failed);
        Assert.Empty(result.Restored);
    }
}
