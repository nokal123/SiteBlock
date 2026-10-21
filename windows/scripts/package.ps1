# Builds SiteBlock for Windows for both kinds of PC and packs everything another PC needs into two files in
# windows/dist/:
#   SiteBlock-Windows.zip    the package, always under this one name so the download link never changes
#   version-windows.json     describes the package (version, build number, commit, file name and SHA-256 checksum),
#                            so the tray app can tell whether a newer build exists and check its download
# The other PC needs no developer tools; it only runs "Install SiteBlock.cmd".
#
#   pwsh windows/scripts/package.ps1
#
# The zip holds one SiteBlock folder:
#   bin/x64/                      the programs for Intel and AMD PCs
#   bin/arm64/                    the programs for Arm PCs
#   scripts/install.ps1           the installer (runs as administrator)
#   scripts/verify-install.ps1    the checks that run after the install
#   Install SiteBlock.cmd         the double-click installer
#   INSTALL.txt                   instructions for the person installing it
#
# It runs in PowerShell 7 on Windows, macOS and Linux, and in Windows PowerShell 5.1.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The windows/ folder of the repository, wherever the script is started from.
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$Dist = Join-Path $WindowsRoot 'dist'
$ZipPath = Join-Path $Dist 'SiteBlock-Windows.zip'
$VersionJsonPath = Join-Path $Dist 'version-windows.json'
$AssetName = 'SiteBlock-Windows.zip'

# The two kinds of PC, as (.NET runtime name, folder name inside the package) pairs.
$Targets = @(
    @{ Runtime = 'win-x64'; Folder = 'x64' },
    @{ Runtime = 'win-arm64'; Folder = 'arm64' }
)
$ProgramNames = @('siteblockd.exe', 'siteblock.exe', 'SiteBlockApp.exe')

# Turns a path made with forward slashes into one for this system, under windows/.
function Join-RepoPath([string]$relative) {
    return (Join-Path $WindowsRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar))
}

# Stops the script with a clear sentence and exit code 1.
function Stop-WithError([string]$message) {
    Write-Host "error: $message" -ForegroundColor Red
    exit 1
}

# Reads one property (such as WindowsSeries) from an MSBuild .props file, or returns $null when it is not there.
function Read-PropsValue([string]$path, [string]$name) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($path)
    $node = $xml.SelectSingleNode("//*[local-name()='$name']")
    if ($null -eq $node) { return $null }
    return $node.InnerText.Trim()
}

# Copies a text file and gives it Windows line endings (CR LF), whatever the line endings of the checked-out copy are.
# cmd.exe misreads a .cmd file with bare LF line endings, and old Notepad shows such a text file as one long line.
function Copy-WithCrLf([string]$source, [string]$destination) {
    $text = [System.IO.File]::ReadAllText($source)
    $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($destination, $text, (New-Object System.Text.UTF8Encoding $false))
}

# Writes the zip with one entry per file, named with forward slashes under SiteBlock/. Entry names are set by hand
# because some .NET Framework versions write backslashes when they build a zip from a folder, and Windows' own
# unzip and ZipFile.ExtractToDirectory both read forward-slash names correctly.
function New-PackageZip([string]$stageFolder, [string]$zipPath) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = (Resolve-Path -LiteralPath $stageFolder).ProviderPath.TrimEnd([char[]]@('\', '/'))
    $stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)) {
                $relative = $file.FullName.Substring($root.Length + 1) -replace '\\', '/'
                $entryName = "SiteBlock/$relative"
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

# Returns the entry names inside a zip file.
function Get-ZipEntryNames([string]$zipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        return @($archive.Entries | ForEach-Object { $_.FullName })
    } finally {
        $archive.Dispose()
    }
}

# Step 1: build both kinds of PC. build.ps1 writes the build number first, so both builds carry the same one.
foreach ($target in $Targets) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Runtime $target.Runtime -Configuration Release
    if ($LASTEXITCODE -ne 0) { Stop-WithError "the $($target.Runtime) build failed, so no package was made." }
}

# Step 2: work out the version. The programs cannot run on a Mac, so the numbers are read from the same files the
# build used: version.props (the series and its first build) and BuildNumber.props (the commit count).
$series = Read-PropsValue (Join-Path $WindowsRoot 'version.props') 'WindowsSeries'
$firstBuildText = Read-PropsValue (Join-Path $WindowsRoot 'version.props') 'WindowsSeriesFirstBuild'
$buildText = Read-PropsValue (Join-Path $WindowsRoot 'BuildNumber.props') 'SiteBlockBuildNumber'
if ($null -eq $series -or $series -notmatch '^\d+\.\d+$') { Stop-WithError "WindowsSeries in version.props must look like 1.0; it is '$series'." }
if ($null -eq $firstBuildText -or $firstBuildText -notmatch '^\d+$') { Stop-WithError "WindowsSeriesFirstBuild in version.props must be a whole number; it is '$firstBuildText'." }
if ($null -eq $buildText -or $buildText -notmatch '^\d+$') { Stop-WithError "BuildNumber.props has no build number; write-build-number.ps1 should have written it." }
$build = [int]$buildText
$patch = [Math]::Max(0, $build - [int]$firstBuildText)
$displayVersion = "$series.$patch"

# On a Windows PC the built daemon can run, so check that it reports the same version this script computed.
$onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$isArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
if ($onWindows) {
    $nativeRuntime = 'win-x64'
    if ($isArm) { $nativeRuntime = 'win-arm64' }
    $versionLine = & (Join-RepoPath "build/$nativeRuntime/siteblockd.exe") --version
    $expected = "siteblockd $displayVersion (build $build)"
    if ("$versionLine".Trim() -ne $expected) { Stop-WithError "siteblockd --version printed '$versionLine', but the package version is '$expected'." }
}

# Step 3: assemble the package folder. Any older package and version file are removed first.
$stage = Join-Path $Dist 'stage'
$stageRoot = Join-Path $stage 'SiteBlock'
foreach ($old in @($stage, $ZipPath, $VersionJsonPath)) {
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
}
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'scripts') -Force | Out-Null

foreach ($target in $Targets) {
    $source = Join-RepoPath "build/$($target.Runtime)"
    $destination = Join-Path (Join-Path $stageRoot 'bin') $target.Folder
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
}
Copy-WithCrLf (Join-RepoPath 'scripts/install.ps1') (Join-Path $stageRoot 'scripts/install.ps1')
Copy-WithCrLf (Join-RepoPath 'scripts/verify-install.ps1') (Join-Path $stageRoot 'scripts/verify-install.ps1')
Copy-WithCrLf (Join-RepoPath 'Install SiteBlock.cmd') (Join-Path $stageRoot 'Install SiteBlock.cmd')
Copy-WithCrLf (Join-RepoPath 'INSTALL.txt') (Join-Path $stageRoot 'INSTALL.txt')

# Step 4: check every program for both kinds of PC is in the folder before anything is zipped.
foreach ($target in $Targets) {
    foreach ($name in $ProgramNames) {
        $exe = Join-Path (Join-Path (Join-Path $stageRoot 'bin') $target.Folder) $name
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Stop-WithError "the package is missing bin/$($target.Folder)/$name." }
    }
}

# Step 5: zip it, then read the zip back and check that every file the installer and the updater need is inside,
# under the names they look for.
New-PackageZip $stageRoot $ZipPath
Remove-Item -LiteralPath $stage -Recurse -Force
$entries = Get-ZipEntryNames $ZipPath
$required = @('SiteBlock/scripts/install.ps1', 'SiteBlock/scripts/verify-install.ps1', 'SiteBlock/Install SiteBlock.cmd', 'SiteBlock/INSTALL.txt')
foreach ($target in $Targets) {
    foreach ($name in $ProgramNames) { $required += "SiteBlock/bin/$($target.Folder)/$name" }
}
foreach ($name in $required) {
    if ($entries -notcontains $name) { Stop-WithError "the finished zip does not contain $name." }
}

# Step 6: describe the package. The commit is the full 40-character hash of the checked-out commit; without git it is
# all zeros (and the build number is then 0, which the tray app never offers as an update). The checksum is lowercase.
$commit = ''
try {
    $commit = "$(& git -C $WindowsRoot rev-parse HEAD 2>$null)".Trim()
} catch {
    $commit = ''
}
if ($commit -notmatch '^[0-9a-f]{40}$') { $commit = '0' * 40 }
$sha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
# "version" is the technical id 1.0.<build>, the same scheme as the Mac's version.json; "displayVersion" is the number people see.
$json = "{`n  `"version`": `"1.0.$build`",`n  `"build`": $build,`n  `"displayVersion`": `"$displayVersion`",`n  `"commit`": `"$commit`",`n  `"asset`": `"$AssetName`",`n  `"sha256`": `"$sha256`"`n}`n"
[System.IO.File]::WriteAllText($VersionJsonPath, $json, (New-Object System.Text.UTF8Encoding $false))

$sizeMb = [Math]::Round((Get-Item -LiteralPath $ZipPath).Length / 1MB, 1)
Write-Host ''
Write-Host "Package ready: $ZipPath ($sizeMb MB)"
Write-Host "Version file: $VersionJsonPath (version $displayVersion, build $build, sha256 $sha256)"
Write-Host 'Send the zip to the other PC and follow INSTALL.txt inside it.'

# Exit 0 on purpose, so the workflow step never sees a leftover code from a native command.
exit 0
