using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>
/// The file rules of a Windows update: what the unzipped package must hold, the check of a downloaded zip, and the PowerShell script that the UAC prompt runs with administrator rights.
/// Nothing here downloads or starts a program; the <see cref="Updater"/> does that.
/// </summary>
public static class UpdatePackage
{
    /// <summary>The exit code the elevated script uses when its own checksum or layout check fails.</summary>
    public const int ChecksFailedExitCode = 3;

    /// <summary>The log the elevated install step writes, under the SiteBlock data folder.</summary>
    public const string UpdateLogPath = @"C:\ProgramData\SiteBlock\Logs\update.log";

    /// <summary>The three programs every processor folder of the package holds.</summary>
    public static IReadOnlyList<string> ProgramNames { get; } = ["siteblockd.exe", "siteblock.exe", "SiteBlockApp.exe"];

    /// <summary>The package folder name for a processor: "arm64" for Arm PCs and "x64" for every other (Intel and AMD) PC.</summary>
    public static string ArchitectureFolderFor(Architecture architecture) => architecture == Architecture.Arm64 ? "arm64" : "x64";

    /// <summary>The folders the unzipped package must contain, as lists of path parts below the unzip folder, for the PC's processor folder <paramref name="architectureFolder"/>.</summary>
    public static IReadOnlyList<string[]> RequiredFolders(string architectureFolder) =>
    [
        ["SiteBlock"],
        ["SiteBlock", "bin"],
        ["SiteBlock", "bin", architectureFolder],
        ["SiteBlock", "scripts"],
    ];

    /// <summary>The files the unzipped package must contain: the three programs for this processor, the installer script and the double-click installer.</summary>
    public static IReadOnlyList<string[]> RequiredFiles(string architectureFolder)
    {
        var files = ProgramNames.Select(name => new[] { "SiteBlock", "bin", architectureFolder, name }).ToList();
        files.Add(["SiteBlock", "scripts", "install.ps1"]);
        files.Add(["SiteBlock", "Install SiteBlock.cmd"]);
        return files;
    }

    /// <summary>
    /// Checks a downloaded package as the person's own account, so a bad package is refused before any UAC prompt: the zip's SHA-256 must equal <paramref name="expectedSha256"/>, it must unzip (into a new <c>unzipped</c> folder inside <paramref name="folder"/>) without any entry leaving that folder,
    /// and every required folder and file must exist as the right kind of item and not as a link. Returns false on any failure; it never throws.
    /// </summary>
    public static bool Verify(string folder, string zipPath, string expectedSha256, string architectureFolder)
    {
        try
        {
            if (!UpdateCheck.MatchesChecksum(zipPath, expectedSha256)) return false;
            string unzipped = Path.Combine(folder, "unzipped");
            if (Directory.Exists(unzipped) || File.Exists(unzipped)) return false;
            Directory.CreateDirectory(unzipped);
            // ExtractToDirectory refuses an entry whose name points outside the folder (such as ..\..\evil.exe) by throwing.
            ZipFile.ExtractToDirectory(zipPath, unzipped);
            return LayoutIsComplete(unzipped, architectureFolder);
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>True when every required folder and file exists below <paramref name="unzipped"/> as a real folder or file. A link (a reparse point) does not count, because it could point anywhere.</summary>
    public static bool LayoutIsComplete(string unzipped, string architectureFolder)
    {
        foreach (string[] parts in RequiredFolders(architectureFolder))
        {
            var info = new DirectoryInfo(Path.Combine([unzipped, .. parts]));
            if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) return false;
        }
        foreach (string[] parts in RequiredFiles(architectureFolder))
        {
            var info = new FileInfo(Path.Combine([unzipped, .. parts]));
            if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) return false;
        }
        return true;
    }

    /// <summary>Deletes a folder this app created, with everything in it. A failure is ignored, because the folder is in a temporary place.</summary>
    public static void DeleteFolder(string folder)
    {
        try
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
        catch (Exception)
        {
            // Left for Windows' own temp clean-up.
        }
    }

    /// <summary>Writes text as a PowerShell single-quoted string, doubling each single quote inside it, so PowerShell reads the text exactly as it is.</summary>
    public static string PowerShellQuoted(string text) => "'" + text.Replace("'", "''", StringComparison.Ordinal) + "'";

    /// <summary>
    /// The PowerShell script the UAC prompt runs. Nothing the person's account can write is trusted after the prompt: the script copies the zip into a new folder <c>C:\ProgramData\SiteBlock\update-&lt;random&gt;</c> that only SYSTEM and Administrators may change,
    /// checks the SHA-256 again there, unzips it there, checks the layout again, and runs that copy's install.ps1. It deletes nothing outside its own update folder: the download folder in the
    /// person's temp folder is deleted by the app, because a recursive delete running as administrator in a folder the person can change could be led through a planted link to other files. Everything it does goes to <see cref="UpdateLogPath"/>.
    /// It exits with install.ps1's exit code, with <see cref="ChecksFailedExitCode"/> when its own checks fail, and with 1 for any other problem. The update folder is deleted at the end.
    /// Throws <see cref="ArgumentException"/> when the checksum is not 64 lowercase hex characters or the processor folder is not x64 or arm64, because both are written into the script.
    /// </summary>
    public static string ElevatedScript(string zipPath, string expectedSha256, string architectureFolder)
    {
        ArgumentNullException.ThrowIfNull(zipPath);
        if (expectedSha256 is not { Length: 64 } || !expectedSha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')) throw new ArgumentException("The checksum must be 64 lowercase hex characters.", nameof(expectedSha256));
        if (architectureFolder is not ("x64" or "arm64")) throw new ArgumentException("The processor folder must be x64 or arm64.", nameof(architectureFolder));

        string folders = string.Join(", ", RequiredFolders(architectureFolder).Select(parts => PowerShellQuoted(string.Join('\\', parts))));
        string files = string.Join(", ", RequiredFiles(architectureFolder).Select(parts => PowerShellQuoted(string.Join('\\', parts))));
        var script = new StringBuilder();
        script.AppendLine("$ErrorActionPreference = 'Stop'");
        // Windows PowerShell 5.1 loads commands written in PowerShell, such as Get-FileHash, from the folders in PSModulePath. A process started from PowerShell 7 (or
        // from a program it started) carries 7's folders there, and 5.1 then cannot find those commands, so the path is put back to Windows PowerShell's own before anything runs.
        // install.ps1, started below, inherits the corrected path.
        script.AppendLine("$env:PSModulePath = (@([Environment]::GetEnvironmentVariable('PSModulePath', 'Machine'), (Join-Path $PSHOME 'Modules')) | Where-Object { $_ }) -join ';'");
        script.AppendLine("$code = 1");
        script.AppendLine("$root = $null");
        script.AppendLine($"$source = {PowerShellQuoted(zipPath)}");
        script.AppendLine($"$expected = '{expectedSha256}'");
        script.AppendLine("$dataDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'SiteBlock'");
        script.AppendLine("$logDir = Join-Path $dataDir 'Logs'");
        script.AppendLine("$log = Join-Path $logDir 'update.log'");
        // Each line gets a timestamp; a failure to write the log never stops the update.
        script.AppendLine("function Write-Log([string]$text) { try { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('o') + ' ' + $text) -Encoding UTF8 } catch { } }");
        // True when the item exists as the wanted kind (folder or file) and is not a link.
        script.AppendLine("function Test-Item([string]$path, [bool]$folder) { $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; if ($null -eq $item) { return $false }; if ([bool]$item.PSIsContainer -ne $folder) { return $false }; return (([int]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) -eq 0) }");
        script.AppendLine("try {");
        // The data folder exists on every installed PC and its access list keeps ordinary users out; without it the install is too broken to update.
        script.AppendLine("    if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) { throw 'The SiteBlock data folder is missing.' }");
        script.AppendLine("    New-Item -ItemType Directory -Force -Path $logDir | Out-Null");
        script.AppendLine("    Write-Log 'update started'");
        script.AppendLine("    $root = Join-Path $dataDir ('update-' + [guid]::NewGuid().ToString('N'))");
        script.AppendLine("    New-Item -ItemType Directory -Path $root | Out-Null");
        // The folder gets its own access list, so it is closed to ordinary users whatever its parent allows.
        script.AppendLine("    & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null");
        script.AppendLine("    if ($LASTEXITCODE -ne 0) { throw 'The update folder could not be protected.' }");
        script.AppendLine("    $zip = Join-Path $root 'SiteBlock-Windows.zip'");
        script.AppendLine("    Copy-Item -LiteralPath $source -Destination $zip");
        // The checksum is computed again on the protected copy, so a file swapped in the temp folder after the app's check is never run.
        script.AppendLine("    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()");
        script.AppendLine("    if ($actual -ne $expected) {");
        script.AppendLine("        Write-Log 'the downloaded package does not match its checksum'");
        script.AppendLine($"        $code = {ChecksFailedExitCode}");
        script.AppendLine("    } else {");
        script.AppendLine("        $unzipped = Join-Path $root 'unzipped'");
        // The .NET unzip is much faster than Expand-Archive for a package of several hundred files, and it refuses an entry whose name points outside the folder.
        script.AppendLine("        Add-Type -AssemblyName System.IO.Compression.FileSystem");
        script.AppendLine("        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unzipped)");
        script.AppendLine("        $complete = $true");
        script.AppendLine($"        foreach ($part in @({folders})) {{ if (-not (Test-Item (Join-Path $unzipped $part) $true)) {{ $complete = $false }} }}");
        script.AppendLine($"        foreach ($part in @({files})) {{ if (-not (Test-Item (Join-Path $unzipped $part) $false)) {{ $complete = $false }} }}");
        script.AppendLine("        if (-not $complete) {");
        script.AppendLine("            Write-Log 'the package is missing a required file'");
        script.AppendLine($"            $code = {ChecksFailedExitCode}");
        script.AppendLine("        } else {");
        script.AppendLine("            Write-Log 'running install.ps1'");
        script.AppendLine("            $installer = Join-Path $unzipped 'SiteBlock\\scripts\\install.ps1'");
        script.AppendLine("            $powershell = Join-Path $env:SystemRoot 'System32\\WindowsPowerShell\\v1.0\\powershell.exe'");
        // A native program's error output must not stop this script, so errors only continue while install.ps1 runs.
        script.AppendLine("            $ErrorActionPreference = 'Continue'");
        script.AppendLine("            $output = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer 2>&1 | ForEach-Object { $_.ToString() }");
        script.AppendLine("            $code = $LASTEXITCODE");
        script.AppendLine("            $ErrorActionPreference = 'Stop'");
        script.AppendLine("            if ($output) { Add-Content -LiteralPath $log -Value $output -Encoding UTF8 }");
        script.AppendLine("            Write-Log ('install.ps1 exited with code ' + $code)");
        script.AppendLine("        }");
        script.AppendLine("    }");
        script.AppendLine("} catch {");
        script.AppendLine("    Write-Log ('update failed: ' + $_.Exception.Message)");
        script.AppendLine("    $code = 1");
        script.AppendLine("} finally {");
        script.AppendLine("    if ($root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }");
        script.AppendLine("}");
        script.AppendLine("exit $code");
        return script.ToString();
    }
}
