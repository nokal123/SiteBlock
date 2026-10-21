# Builds the three SiteBlock for Windows programs (siteblockd.exe, siteblock.exe and SiteBlockApp.exe) in one
# folder, windows/build/<runtime>/, for one kind of Windows PC: win-x64 (Intel and AMD) or win-arm64 (Arm).
# The folder is self-contained: the .NET runtime ships inside it, so the PC it is copied to needs nothing installed.
# All three programs are published into the same folder, so they share one copy of the runtime files.
#
#   powershell -ExecutionPolicy Bypass -File windows\scripts\build.ps1                 (this PC's processor)
#   pwsh windows/scripts/build.ps1 -Runtime win-x64                                    (also works on a Mac)
#
# It needs the .NET 10 SDK. It runs in Windows PowerShell 5.1 and in PowerShell 7 on Windows, macOS and Linux,
# because "Install SiteBlock.cmd" runs it with Windows PowerShell when someone installs from the repository.
[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = '',
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The windows/ folder of the repository, wherever the script is started from.
$WindowsRoot = Split-Path -Parent $PSScriptRoot

# The three programs, as (project file, program name) pairs.
$Programs = @(
    @{ Project = 'src/siteblockd/siteblockd.csproj'; Exe = 'siteblockd.exe' },
    @{ Project = 'src/siteblock/siteblock.csproj'; Exe = 'siteblock.exe' },
    @{ Project = 'src/SiteBlockApp/SiteBlockApp.csproj'; Exe = 'SiteBlockApp.exe' }
)

# True when this script runs on Windows. $IsWindows does not exist in Windows PowerShell 5.1, so ask .NET instead.
function Test-OnWindows {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

# Returns the .NET runtime name (win-x64 or win-arm64) that matches this computer's processor.
function Get-MachineRuntime {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($arch -eq [System.Runtime.InteropServices.Architecture]::Arm64) { return 'win-arm64' }
    return 'win-x64'
}

# Turns a path made with forward slashes into one for this system.
function Join-RepoPath([string]$relative) {
    return (Join-Path $WindowsRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar))
}

if ($Runtime -eq '') { $Runtime = Get-MachineRuntime }
$OutDir = Join-RepoPath "build/$Runtime"

# Refuse early with a clear sentence when the .NET SDK is missing.
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host 'error: the .NET SDK was not found. Install the .NET 10 SDK from https://dotnet.microsoft.com/download and run this again.' -ForegroundColor Red
    exit 1
}

# Write the build number (the commit count) first, so every program carries the same version.
& (Join-Path $PSScriptRoot 'write-build-number.ps1')

# Start from an empty output folder, so no file from an older build is left behind.
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# Publish each program into the same folder. Publishing one project at a time is what makes a shared folder work:
# each publish copies the same runtime files (they come from the same SDK, so they are identical) and adds its own
# program, its .deps.json and its .runtimeconfig.json, whose names never collide.
# PublishSingleFile=false keeps the runtime as separate files that the three programs share.
# UseAppHost=true makes a real .exe for each program, which the WPF tray app needs when it is cross-built from a Mac.
foreach ($program in $Programs) {
    $project = Join-RepoPath $program.Project
    Write-Host "==> Publishing $($program.Exe) for $Runtime ($Configuration)"
    & dotnet publish $project -c $Configuration -r $Runtime --self-contained true -p:PublishSingleFile=false -p:UseAppHost=true -o $OutDir --nologo
    if ($LASTEXITCODE -ne 0) {
        Write-Host "error: building $($program.Exe) failed (dotnet publish exit code $LASTEXITCODE). Read the messages above." -ForegroundColor Red
        exit 1
    }
}

# Check that every program really landed in the folder.
foreach ($program in $Programs) {
    $exe = Join-Path $OutDir $program.Exe
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Write-Host "error: expected program not found after the build: $exe" -ForegroundColor Red
        exit 1
    }
}

# Show the version, but only where the program can run: on Windows, built for this PC's own processor.
if ((Test-OnWindows) -and ($Runtime -eq (Get-MachineRuntime))) {
    $versionLine = & (Join-Path $OutDir 'siteblockd.exe') --version
    Write-Host ''
    Write-Host "Built $versionLine"
} else {
    Write-Host ''
    Write-Host "Built SiteBlock for $Runtime (the version is not printed, because these programs cannot run on this computer)."
}
Write-Host "  $OutDir"
# Exit 0 on purpose, so a caller that checks $LASTEXITCODE (package.ps1) never sees a leftover code from a native command.
exit 0
