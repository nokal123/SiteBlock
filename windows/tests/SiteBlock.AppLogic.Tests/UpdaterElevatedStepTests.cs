using SiteBlock.AppLogic;
using SiteBlock.Core;
using static SiteBlock.AppLogic.Tests.Fixtures;

namespace SiteBlock.AppLogic.Tests;

// The elevated install step of the Windows updater: what the script given to the UAC prompt does, and how the updater reports each way that step can end.
// Expected values come from 06-windows.md § Updater (Installing, steps 2 and 3: the copy into C:\ProgramData\SiteBlock\update-<random>, the second checksum there, unzipping there,
// running that copy's install.ps1, the update.log, "The update didn't pass its checks, so nothing was installed." and "The update was cancelled.") and 03-daemon-cli-app.md § Updater.
// The exit-code contract between the script and the app (UpdatePackage.ChecksFailedExitCode, Updater.StartFailedText, Updater.InstallFailedText) is not worded in the design;
// those tests use the constants and pin only what the design implies about them.
public sealed class ElevatedScriptStructureTests
{
    private const string Sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    private const string DownloadFolder = @"C:\Users\Dana\AppData\Local\Temp\SiteBlockUpdate-1a2b";
    private const string DownloadedZip = DownloadFolder + @"\SiteBlock-Windows.zip";

    // The script's lines with their indentation removed, so a test can pin a whole line.
    private static List<string> Lines(string architecture = "x64") =>
        [.. UpdatePackage.ElevatedScript(DownloadedZip, Sha, architecture).Split('\n').Select(line => line.TrimEnd('\r').Trim())];

    // A recursive delete running as administrator in a folder the person can change (the download folder in their temp folder) could be led through a planted link to other files,
    // so the only thing the elevated script may delete is its own protected update folder ($root), and the person's download folder never appears in it.
    [Theory]
    [InlineData("x64")]
    [InlineData("arm64")]
    public void ElevatedScript_DeletesOnlyItsOwnUpdateFolder(string architecture)
    {
        var lines = Lines(architecture);
        var deletes = lines.Where(line => line.Contains("Remove-Item", StringComparison.OrdinalIgnoreCase) || line.Contains("Delete(", StringComparison.Ordinal)).ToList();
        Assert.All(deletes, line => Assert.Contains("-LiteralPath $root ", line));
        Assert.DoesNotContain(lines, line => line.Contains(DownloadFolder + "'", StringComparison.OrdinalIgnoreCase));
    }

    // The index of the one line exactly equal to the text; fails when there is none or more than one.
    private static int Single(List<string> lines, string text)
    {
        var found = Enumerable.Range(0, lines.Count).Where(i => lines[i] == text).ToList();
        Assert.True(found.Count == 1, $"expected exactly one line \"{text}\", found {found.Count}:\n{string.Join('\n', lines)}");
        return found[0];
    }

    // Brace depth before and after each line, ignoring braces inside single-quoted PowerShell text, plus the lowest depth reached during the line.
    private static (int[] After, int[] Lowest) Depths(List<string> lines)
    {
        var after = new int[lines.Count];
        var lowest = new int[lines.Count];
        int depth = 0;
        for (int i = 0; i < lines.Count; i++)
        {
            bool quoted = false;
            int low = depth;
            foreach (char c in lines[i])
            {
                if (c == '\'') quoted = !quoted;
                else if (!quoted && c == '{') depth++;
                else if (!quoted && c == '}') low = Math.Min(low, --depth);
            }
            after[i] = depth;
            lowest[i] = low;
        }
        return (after, lowest);
    }

    // The index of the line that closes the block opened at the end of line `open` (a line such as "} else {" closes one block and opens the next).
    private static int BlockEnd(List<string> lines, int open)
    {
        var (after, lowest) = Depths(lines);
        Assert.True(lines[open].EndsWith('{'), $"line {open} does not open a block: {lines[open]}");
        for (int k = open + 1; k < lines.Count; k++) if (lowest[k] < after[open]) return k;
        throw new Xunit.Sdk.XunitException($"the block opened at line {open} never closes");
    }

    [Fact]
    public void Script_CopiesTheZipIntoAFreshProgramDataUpdateFolderBeforeAnythingElseUsesIt()
    {
        var lines = Lines();

        int assigned = Single(lines, $"$source = '{DownloadedZip}'");
        Single(lines, "$dataDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'SiteBlock'");
        int root = Single(lines, "$root = Join-Path $dataDir ('update-' + [guid]::NewGuid().ToString('N'))");
        int create = Single(lines, "New-Item -ItemType Directory -Path $root | Out-Null");
        int zip = Single(lines, "$zip = Join-Path $root 'SiteBlock-Windows.zip'");
        int copy = Single(lines, "Copy-Item -LiteralPath $source -Destination $zip");
        Assert.True(root < create && create < zip && zip < copy, "the update folder must be made before the zip is copied into it");
        // After the copy, nothing reads the person's own file again: the only lines that name $source are its assignment and the copy.
        Assert.Equal([assigned, copy], Enumerable.Range(0, lines.Count).Where(i => lines[i].Contains("$source", StringComparison.Ordinal)));
    }

    [Fact]
    public void Script_HashesTheProtectedCopyAndComparesItWithTheExpectedChecksum()
    {
        var lines = Lines();

        int copy = Single(lines, "Copy-Item -LiteralPath $source -Destination $zip");
        int expected = Single(lines, $"$expected = '{Sha}'");
        int hash = Single(lines, "$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()");
        int compare = Single(lines, "if ($actual -ne $expected) {");
        Assert.True(expected < compare && copy < hash && hash < compare);
        // The only hash in the script is of the protected copy.
        Assert.Single(lines, line => line.Contains("Get-FileHash", StringComparison.Ordinal));
        // Unzipping also reads the protected copy, into a folder inside the update folder.
        int unzipped = Single(lines, "$unzipped = Join-Path $root 'unzipped'");
        int extract = Single(lines, "[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unzipped)");
        Assert.True(compare < unzipped && unzipped < extract);
    }

    [Fact]
    public void Script_RunsInstallPs1OnlyWhereTheHashMatchedAndTheLayoutIsComplete()
    {
        var lines = Lines();

        int compare = Single(lines, "if ($actual -ne $expected) {");
        int hashElse = BlockEnd(lines, compare);
        Assert.Equal("} else {", lines[hashElse]);
        int hashElseEnd = BlockEnd(lines, hashElse);

        // The mismatch branch records the checks-failed code and runs nothing.
        var mismatch = lines.GetRange(compare + 1, hashElse - compare - 1);
        Assert.Contains($"$code = {UpdatePackage.ChecksFailedExitCode}", mismatch);
        Assert.DoesNotContain(mismatch, line => line.Contains("install.ps1", StringComparison.Ordinal) || line.Contains("-File", StringComparison.Ordinal));

        // The layout is checked again on the unzipped copy, after the unzip and before the run.
        int extract = Single(lines, "[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unzipped)");
        int incomplete = Single(lines, "if (-not $complete) {");
        int layoutElse = BlockEnd(lines, incomplete);
        Assert.Equal("} else {", lines[layoutElse]);
        int layoutElseEnd = BlockEnd(lines, layoutElse);
        var checks = Enumerable.Range(0, lines.Count).Where(i => lines[i].StartsWith("foreach ($part in @(", StringComparison.Ordinal) && lines[i].Contains("Test-Item (Join-Path $unzipped $part)", StringComparison.Ordinal)).ToList();
        Assert.Equal(2, checks.Count);
        Assert.All(checks, i => Assert.True(extract < i && i < incomplete, $"layout check at line {i} is not between the unzip and the decision"));
        foreach (string file in new[] { @"'SiteBlock\bin\x64\siteblockd.exe'", @"'SiteBlock\bin\x64\siteblock.exe'", @"'SiteBlock\bin\x64\SiteBlockApp.exe'", @"'SiteBlock\scripts\install.ps1'", @"'SiteBlock\Install SiteBlock.cmd'" })
        {
            Assert.Contains(checks, i => lines[i].Contains(file, StringComparison.Ordinal));
        }
        Assert.Contains($"$code = {UpdatePackage.ChecksFailedExitCode}", lines.GetRange(incomplete + 1, layoutElse - incomplete - 1));

        // The one run of install.ps1 is the unzipped copy's, inside both "else" branches.
        int installer = Single(lines, @"$installer = Join-Path $unzipped 'SiteBlock\scripts\install.ps1'");
        var runs = Enumerable.Range(0, lines.Count).Where(i => lines[i].Contains("-File $installer", StringComparison.Ordinal)).ToList();
        int run = Assert.Single(runs);
        Assert.True(hashElse < incomplete && incomplete < hashElseEnd, "the layout decision must sit inside the branch where the hash matched");
        Assert.True(layoutElse < installer && installer < run && run < layoutElseEnd, "install.ps1 must run only inside the branch where the layout is complete");
        Assert.True(run < hashElseEnd);
        Assert.Equal("exit $code", lines.Last(line => line.Length > 0));
    }

    [Fact]
    public void Script_ForAnArmPc_ChecksTheArm64ProgramsOnly()
    {
        var lines = Lines("arm64");

        Assert.Contains(lines, line => line.Contains(@"'SiteBlock\bin\arm64\siteblockd.exe'", StringComparison.Ordinal));
        Assert.DoesNotContain(lines, line => line.Contains(@"bin\x64", StringComparison.Ordinal));
    }
}

public sealed class UpdaterElevatedOutcomeTests : UpdaterTestBase
{
    private const string ChecksFailed = "The update didn't pass its checks, so nothing was installed.";

    // A runner that throws (synchronously, or through the returned task) instead of reporting an outcome, as a broken ShellExecute would.
    private sealed class ThrowingRunner(bool throwInsideTask) : IElevatedRunner
    {
        public int Calls { get; private set; }

        public Task<ElevatedRunResult> RunAsync(string fileName, string arguments, Action onStarted, TimeSpan timeout, CancellationToken ct)
        {
            Calls++;
            if (throwInsideTask) return Task.FromException<ElevatedRunResult>(new System.ComponentModel.Win32Exception(2));
            throw new InvalidOperationException("powershell.exe could not be found");
        }
    }

    // An updater that has found build 143 with a complete, correctly hashed package, using the given runner.
    private async Task<Updater> ReadyWith(IElevatedRunner runner)
    {
        byte[] package = Zip(PackageEntries());
        Downloader.VersionFile = () => VersionFile(143, Sha256(package), "1.0.43");
        Downloader.Package = package;
        var updater = new Updater(Downloader, runner, Store, Clock, new InlineUiDispatcher(), new UpdaterOptions { InstalledBuild = Installed, TempRoot = Root, ArchitectureFolder = "x64" });
        await updater.CheckNowAsync();
        Assert.NotNull(updater.Available);
        return updater;
    }

    // The checks shared by every failed ending: a failure with this sentence, the offer still on screen, and no download folder left behind.
    private void AssertFailedWith(Updater updater, string text)
    {
        Assert.Equal(UpdatePhaseKind.Failed, updater.Phase.Kind);
        Assert.Equal(text, updater.Phase.FailureText);
        Assert.Equal(143, updater.Available?.Build);
        Assert.True(updater.ShowsBanner);
        Assert.Equal(text, Banners.UpdateBanner(updater.Available!, updater).ErrorText);
        Assert.Null(updater.Notice);
        Assert.Empty(DownloadFolders());
    }

    [Fact]
    public async Task ElevatedStepExitsWithTheChecksFailedCode_SaysTheUpdateDidNotPassItsChecks()
    {
        Runner.Result = new ElevatedRunResult(ElevatedRunOutcome.Exited, UpdatePackage.ChecksFailedExitCode);
        Updater updater = await ReadyWith(Runner);

        await updater.InstallAsync();

        AssertFailedWith(updater, ChecksFailed);
        Assert.Equal(ChecksFailed, Updater.ChecksFailedText);
        Assert.Single(Runner.Runs);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(-1)]
    [InlineData(4)]
    public async Task ElevatedStepExitsWithAnotherNonZeroCode_SaysTheInstallDidNotFinishAndNamesTheLog(int exitCode)
    {
        Runner.Result = new ElevatedRunResult(ElevatedRunOutcome.Exited, exitCode);
        Updater updater = await ReadyWith(Runner);

        await updater.InstallAsync();

        AssertFailedWith(updater, Updater.InstallFailedText);
        // The installer's output goes to the update log (06-windows.md § Updater step 3), so the sentence must send the person there.
        Assert.Contains(@"C:\ProgramData\SiteBlock\Logs\update.log", Updater.InstallFailedText, StringComparison.Ordinal);
        Assert.NotEqual(ChecksFailed, Updater.InstallFailedText);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ElevatedRunnerThrows_SaysTheInstallerCouldNotBeStarted(bool throwInsideTask)
    {
        var runner = new ThrowingRunner(throwInsideTask);
        Updater updater = await ReadyWith(runner);

        await updater.InstallAsync();

        Assert.Equal(1, runner.Calls);
        AssertFailedWith(updater, Updater.StartFailedText);
    }

    [Fact]
    public async Task ElevatedRunnerReportsItCouldNotStart_SaysTheInstallerCouldNotBeStarted()
    {
        Runner.Result = new ElevatedRunResult(ElevatedRunOutcome.Failed);
        Updater updater = await ReadyWith(Runner);

        await updater.InstallAsync();

        AssertFailedWith(updater, Updater.StartFailedText);
        Assert.NotEqual(Updater.StartFailedText, Updater.InstallFailedText);
    }

    [Fact]
    public async Task ElevatedStepTimesOut_IsAFailureThatNeverClaimsNothingWasInstalledOrThatItWasCancelled()
    {
        // Spec gap: 06-windows.md does not word the timeout case. The installer may still be running when the wait ends, so the sentence must not say
        // "nothing was installed" (the checks-failed and could-not-start sentences) and the offer must not be cleared as if the update had finished.
        Runner.Result = new ElevatedRunResult(ElevatedRunOutcome.TimedOut);
        Updater updater = await ReadyWith(Runner);

        await updater.InstallAsync();

        Assert.Equal(UpdatePhaseKind.Failed, updater.Phase.Kind);
        Assert.False(string.IsNullOrWhiteSpace(updater.Phase.FailureText));
        Assert.DoesNotContain("nothing was installed", updater.Phase.FailureText, StringComparison.Ordinal);
        Assert.NotEqual(Updater.CancelledText, updater.Phase.FailureText);
        Assert.Null(updater.Notice);
        Assert.Equal(143, updater.Available?.Build);
        Assert.Empty(DownloadFolders());
    }

    [Fact]
    public async Task ElevatedStepExitsWithZero_ClearsTheOfferWithNoFailure()
    {
        // Control for the failure tests: the same setup with exit code 0 is a finished update.
        Runner.Result = new ElevatedRunResult(ElevatedRunOutcome.Exited, 0);
        Updater updater = await ReadyWith(Runner);

        await updater.InstallAsync();

        Assert.Equal(UpdatePhaseKind.Idle, updater.Phase.Kind);
        Assert.Null(updater.Available);
        Assert.False(updater.ShowsBanner);
    }
}
