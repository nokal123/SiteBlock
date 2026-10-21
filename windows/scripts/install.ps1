# Installs SiteBlock for Windows, or upgrades or repairs an existing install. It copies the three programs into
# C:\Program Files\SiteBlock, keeps a backup copy in C:\ProgramData\SiteBlock\backup\app, sets up the two Windows
# services (SiteBlock and SiteBlockWatchdog), adds SiteBlock to the system PATH, makes the tray app start at every
# sign-in, adds a Start menu shortcut, starts the services and checks that SiteBlock answers.
#
# It must run as administrator. "Install SiteBlock.cmd" starts it that way; by hand:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1
#
# It is safe to run again. It never touches C:\ProgramData\SiteBlock\state\, so the blocked sites, the password and
# every countdown survive an upgrade or a repair.
#
# It finds the programs in one of two places: bin\x64\ or bin\arm64\ next to the scripts folder (the package from
# GitHub), or build\win-x64\ or build\win-arm64\ (a build made from the repository with scripts\build.ps1).
# It runs in Windows PowerShell 5.1, the version every Windows 10 and 11 PC has.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A 32-bit PowerShell on 64-bit Windows sees a different Program Files folder and a different part of the registry,
# so start the 64-bit PowerShell instead and pass on its result.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativePowerShell = Join-Path $env:windir 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    & $nativePowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

# Every location SiteBlock installs to (these match 06-windows.md, Installed Paths and Permissions).
$PackageRoot = Split-Path -Parent $PSScriptRoot
$ProgramDir = Join-Path $env:ProgramFiles 'SiteBlock'
$DataDir = Join-Path $env:ProgramData 'SiteBlock'
$BackupDir = Join-Path $DataDir 'backup'
$BackupAppDir = Join-Path $BackupDir 'app'
$StateDir = Join-Path $DataDir 'state'
$LogDir = Join-Path $DataDir 'Logs'
$DaemonExe = Join-Path $ProgramDir 'siteblockd.exe'
$CliExe = Join-Path $ProgramDir 'siteblock.exe'
$AppExe = Join-Path $ProgramDir 'SiteBlockApp.exe'
$ShortcutPath = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\SiteBlock.lnk'
$PipePath = '\\.\pipe\siteblock'
$ProgramNames = @('siteblockd.exe', 'siteblock.exe', 'SiteBlockApp.exe')

# The two services: name, display name, the flag siteblockd.exe gets, and the description shown in the Services app.
$DaemonService = @{ Name = 'SiteBlock'; Display = 'SiteBlock'; Flag = '--daemon'; Description = 'Blocks the websites chosen in SiteBlock and puts the block back when something changes it.' }
$WatchdogService = @{ Name = 'SiteBlockWatchdog'; Display = 'SiteBlock Watchdog'; Flag = '--watchdog'; Description = 'Keeps the SiteBlock service installed and running.' }

# Well-known security IDs, used instead of group names so the access lists work on Windows in any language.
$SidSystem = '*S-1-5-18'
$SidAdministrators = '*S-1-5-32-544'
$SidUsers = '*S-1-5-32-545'

# Prints a heading for the next group of actions.
function Write-Step([string]$text) {
    Write-Host ''
    Write-Host "==> $text" -ForegroundColor Cyan
}

# Stops the install with a sentence that says what went wrong; the catch block at the bottom prints it.
function Fail([string]$message) {
    throw $message
}

# Runs a program with an exact command line and returns its exit code and everything it printed. The command line is
# passed as one string, so quotes inside it reach the program unchanged in every PowerShell version (PowerShell's own
# argument passing changes embedded quotes differently in 5.1 and 7, and sc.exe needs them exactly).
function Invoke-Native([string]$filePath, [string]$arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $filePath
    $info.Arguments = $arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    # Both streams are read at the same time, so a program that fills one of them can never block.
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return New-Object PSObject -Property @{ ExitCode = $process.ExitCode; Output = ($outTask.Result + $errTask.Result).Trim() }
}

# Runs a program like Invoke-Native and stops the install when it exits with anything but 0.
function Invoke-NativeChecked([string]$filePath, [string]$arguments, [string]$whatItDoes) {
    $result = Invoke-Native $filePath $arguments
    if ($result.ExitCode -ne 0) {
        Fail "could not $whatItDoes ($filePath exit code $($result.ExitCode): $($result.Output))"
    }
}

# True when this PowerShell runs with full administrator rights ("Run as administrator").
function Test-Elevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Returns this PC's processor as the package folder name: x64 for Intel and AMD, arm64 for Arm. A 32-bit PowerShell
# reports its own emulated processor in PROCESSOR_ARCHITECTURE, and the real one in PROCESSOR_ARCHITEW6432.
function Get-PcArchitecture {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrEmpty($arch)) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { Fail "SiteBlock runs on 64-bit Intel, AMD and Arm PCs, and this PC reports the processor type '$arch'." }
    }
}

# Returns the folder that holds the programs for this PC: bin\<arch> in a package, build\win-<arch> in the repository.
function Get-ProgramSource([string]$arch) {
    $packageBin = Join-Path $PackageRoot 'bin'
    if (Test-Path -LiteralPath $packageBin -PathType Container) {
        return (Join-Path $packageBin $arch)
    }
    return (Join-Path (Join-Path $PackageRoot 'build') "win-$arch")
}

# Returns the service, or $null when it is not installed.
function Get-ServiceOrNull([string]$name) {
    return (Get-Service -Name $name -ErrorAction SilentlyContinue)
}

# Returns the service's state as text (Running, Stopped, StopPending, ...), or 'Missing' when it is not installed.
function Get-ServiceState([string]$name) {
    $service = Get-ServiceOrNull $name
    if ($null -eq $service) { return 'Missing' }
    return [string]$service.Status
}

# Waits until the service is stopped (or not installed), for at most the given number of seconds. Returns $true when it is.
function Wait-ServiceStopped([string]$name, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $state = Get-ServiceState $name
        if ($state -eq 'Stopped' -or $state -eq 'Missing') { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Asks Windows to stop a service without waiting. A service that is missing or already stopped is left alone.
function Send-ServiceStop([string]$name) {
    $state = Get-ServiceState $name
    if ($state -ne 'Stopped' -and $state -ne 'Missing') {
        Invoke-Native 'sc.exe' "stop $name" | Out-Null
    }
}

# Stops both services so neither restarts the other during the copy. Each one puts the other back within 5 seconds,
# so the stop requests go out back to back (watchdog, service, watchdog again), and the whole round repeats until
# both stay stopped. A siteblockd.exe process that is still running after that is ended.
function Stop-SiteBlockServices {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        Send-ServiceStop $WatchdogService.Name
        Send-ServiceStop $DaemonService.Name
        Send-ServiceStop $WatchdogService.Name
        $watchdogStopped = Wait-ServiceStopped $WatchdogService.Name 15
        $daemonStopped = Wait-ServiceStopped $DaemonService.Name 15
        if ($watchdogStopped -and $daemonStopped) {
            Get-Process -Name 'siteblockd' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            # A second look one second later catches a service that the other one started again in the meantime.
            Start-Sleep -Seconds 1
            $stoppedStates = @('Stopped', 'Missing')
            if (((Get-ServiceState $WatchdogService.Name) -in $stoppedStates) -and ((Get-ServiceState $DaemonService.Name) -in $stoppedStates)) { return }
        }
    }
    Fail 'the running SiteBlock services did not stop. Restart the PC and run the installer again.'
}

# Copies every file of one folder into another and removes files in the destination that the source no longer has.
# robocopy only works inside the destination folder, so nothing outside it is ever removed. Exit codes below 8 mean success.
function Copy-ProgramFolder([string]$source, [string]$destination) {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $result = Invoke-Native 'robocopy.exe' ('"{0}" "{1}" /MIR /R:5 /W:1 /NFL /NDL /NJH /NJS /NP' -f $source, $destination)
    if ($result.ExitCode -ge 8) {
        Fail "could not copy the programs to $destination (robocopy exit code $($result.ExitCode)). Close any window that is running siteblock and try again. $($result.Output)"
    }
}

# Creates a folder when it is missing. An existing folder and its contents are left as they are.
function New-FolderIfMissing([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

# Gives C:\ProgramData\SiteBlock its own access list that does not inherit from C:\ProgramData (where ordinary users
# may create files): SYSTEM and Administrators full control, Users read and run. Subfolders inherit it, except the
# state folder and the backup folder, which both hold the password hash (the state and its backup copy) and give Users nothing.
function Set-DataFolderAccess {
    # An owner may always rewrite a folder's access list, so a folder that an ordinary user created before the install is
    # first given to Administrators.
    foreach ($folder in @($DataDir, $StateDir, $BackupDir)) {
        Invoke-NativeChecked 'icacls.exe' ('"{0}" /setowner {1}' -f $folder, $SidAdministrators) "set the owner of $folder"
    }
    Invoke-NativeChecked 'icacls.exe' ('"{0}" /inheritance:r /grant:r {1}:(OI)(CI)F {2}:(OI)(CI)F {3}:(OI)(CI)RX' -f $DataDir, $SidSystem, $SidAdministrators, $SidUsers) "set the access list of $DataDir"
    foreach ($private in @($StateDir, $BackupDir)) {
        Invoke-NativeChecked 'icacls.exe' ('"{0}" /inheritance:r /grant:r {1}:(OI)(CI)F {2}:(OI)(CI)F' -f $private, $SidSystem, $SidAdministrators) "set the access list of $private"
        # An explicit Users entry left on the folder by hand would survive the step above, so remove it too.
        Invoke-Native 'icacls.exe' ('"{0}" /remove:g {1}' -f $private, $SidUsers) | Out-Null
    }
}

# Creates the service when it is missing, or sets it back to the wanted settings when it exists: its own process,
# starts automatically, runs as LocalSystem, runs siteblockd.exe with its flag. Then sets the recovery actions
# (restart 5 seconds after a failure, three times, failure count reset after one day) and the description.
function Install-SiteBlockService($service) {
    $name = $service.Name
    # The program path is quoted inside the value, because it contains a space; sc.exe reads \" as a quote character.
    $binPath = 'binPath= "\"{0}\" {1}"' -f $DaemonExe, $service.Flag
    $settings = '{0} type= own start= auto obj= LocalSystem DisplayName= "{1}"' -f $binPath, $service.Display
    if ($null -eq (Get-ServiceOrNull $name)) {
        $result = Invoke-Native 'sc.exe' "create $name $settings"
        if ($result.ExitCode -eq 1072) { Fail "Windows still has the old $name service marked for removal. Restart the PC and run the installer again." }
        if ($result.ExitCode -ne 0) { Fail "could not create the $name service (sc.exe exit code $($result.ExitCode): $($result.Output))" }
        Write-Host "created the $name service"
    } else {
        Invoke-NativeChecked 'sc.exe' "config $name $settings" "update the $name service"
        Write-Host "updated the $name service"
    }
    Invoke-NativeChecked 'sc.exe' "failure $name reset= 86400 actions= restart/5000/restart/5000/restart/5000" "set the recovery actions of the $name service"
    Invoke-NativeChecked 'sc.exe' ('description {0} "{1}"' -f $name, $service.Description) "set the description of the $name service"
}

# Starts a service when it is not running, and waits up to 15 seconds for it to run.
function Start-SiteBlockService([string]$name) {
    if ((Get-ServiceState $name) -ne 'Running') {
        Invoke-Native 'sc.exe' "start $name" | Out-Null
    }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if ((Get-ServiceState $name) -eq 'Running') {
            Write-Host "the $name service is running"
            return
        }
        Start-Sleep -Milliseconds 250
    }
    Fail "the $name service did not start. Look at $LogDir\siteblockd.log and $LogDir\watchdog.log."
}

# Opens a key under HKEY_LOCAL_MACHINE in the 64-bit registry, which is where Windows and the browsers look.
function Open-MachineKey([string]$path) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $base.CreateSubKey($path)
    if ($null -eq $key) { Fail "could not open the registry key HKLM\$path" }
    return $key
}

# Adds C:\Program Files\SiteBlock to the system PATH when it is not there yet, so "siteblock" works in any new terminal.
# The value is read without expanding names such as %SystemRoot% and written back with its original type, so the
# entries that use those names keep working.
function Add-ProgramFolderToPath {
    $key = Open-MachineKey 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($key.GetValueNames() -contains 'Path') { $kind = $key.GetValueKind('Path') }
        $wanted = $ProgramDir.TrimEnd('\')
        foreach ($entry in ($raw -split ';')) {
            $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim()).TrimEnd('\')
            if ($expanded -ieq $wanted) {
                Write-Host "$ProgramDir is already in the system PATH"
                return
            }
        }
        $newValue = $raw.TrimEnd(';')
        if ($newValue.Length -gt 0) { $newValue += ';' }
        $newValue += $ProgramDir
        $key.SetValue('Path', $newValue, $kind)
        Write-Host "added $ProgramDir to the system PATH (new terminal windows will find siteblock)"
    } finally {
        $key.Close()
    }
    Send-EnvironmentChanged
}

# Tells running programs (such as Explorer) that the system environment changed, so terminals opened from them see
# the new PATH. This is optional: if it fails, the new PATH still applies after the next sign-in.
function Send-EnvironmentChanged {
    try {
        if (-not ('SiteBlockInstall.NativeMethods' -as [type])) {
            Add-Type -Namespace SiteBlockInstall -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        # HWND_BROADCAST (0xffff), WM_SETTINGCHANGE (0x1a), SMTO_ABORTIFHUNG (2), at most 5 seconds.
        [SiteBlockInstall.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
    } catch {
        Write-Host 'note: could not tell running programs about the new PATH; it applies after the next sign-in.'
    }
}

# Makes Windows start the tray app at every sign-in, for every user.
function Set-StartAtSignIn {
    $key = Open-MachineKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    try {
        $key.SetValue('SiteBlock', ('"{0}"' -f $AppExe), [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        $key.Close()
    }
    Write-Host 'the tray app will start at every sign-in'
}

# Creates (or replaces) the SiteBlock shortcut in the Start menu for every user.
function New-StartMenuShortcut {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $AppExe
    $shortcut.WorkingDirectory = $ProgramDir
    $shortcut.Description = 'SiteBlock'
    $shortcut.IconLocation = "$AppExe,0"
    $shortcut.Save()
    Write-Host "created the Start menu shortcut $ShortcutPath"
}

# Waits up to the given number of seconds for the SiteBlock service to open its pipe. Returns $true when it did.
function Wait-ForPipe([int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $PipePath) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Runs every install step in order.
function Install-SiteBlock {
    Write-Step 'Step 1 of 6: checking this PC and the package'
    if (-not (Test-Elevated)) {
        Fail 'this installer needs administrator rights. Right-click "Install SiteBlock.cmd" and choose "Run as administrator".'
    }
    $arch = Get-PcArchitecture
    $source = Get-ProgramSource $arch
    $missing = @($ProgramNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $source $_) -PathType Leaf) })
    if ($missing.Count -gt 0) {
        if (Test-Path -LiteralPath (Join-Path $PackageRoot 'bin') -PathType Container) {
            Fail "the package is incomplete: $source is missing $($missing -join ', '). Download SiteBlock-Windows.zip again and unzip all of it."
        }
        Fail "$source is missing $($missing -join ', '). Build SiteBlock first with: powershell -ExecutionPolicy Bypass -File scripts\build.ps1"
    }
    Write-Host "this PC has a $arch processor; installing the programs from $source"

    Write-Step 'Step 2 of 6: stopping any running copy of SiteBlock'
    Stop-SiteBlockServices
    Get-Process -Name 'SiteBlockApp' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host 'nothing of SiteBlock is running now (your blocked sites and password are kept)'

    Write-Step 'Step 3 of 6: creating the folders'
    foreach ($folder in @($ProgramDir, $DataDir, $BackupDir, $StateDir, $LogDir)) { New-FolderIfMissing $folder }
    Set-DataFolderAccess
    Write-Host "created $ProgramDir and $DataDir, and set who may read and change them"

    Write-Step 'Step 4 of 6: copying the programs'
    Copy-ProgramFolder $source $ProgramDir
    Copy-ProgramFolder $source $BackupAppDir
    Write-Host "copied the programs to $ProgramDir and a backup copy to $BackupAppDir"

    Write-Step 'Step 5 of 6: setting up the services, the PATH, start at sign-in and the Start menu'
    Install-SiteBlockService $DaemonService
    Install-SiteBlockService $WatchdogService
    Add-ProgramFolderToPath
    Set-StartAtSignIn
    New-StartMenuShortcut

    Write-Step 'Step 6 of 6: starting SiteBlock'
    Start-SiteBlockService $DaemonService.Name
    Start-SiteBlockService $WatchdogService.Name
    if (-not (Wait-ForPipe 10)) {
        Fail "the SiteBlock service did not start answering within 10 seconds. Look at $LogDir\siteblockd.log."
    }
    & $CliExe status
    if ($LASTEXITCODE -ne 0) {
        Fail "siteblock status did not work (exit code $LASTEXITCODE). Look at $LogDir\siteblockd.log."
    }

    Write-Host ''
    Write-Host 'SiteBlock is installed.' -ForegroundColor Green
    Write-Host 'Next steps:'
    Write-Host '  1. Click the shield icon by the clock, type a site and press Block.'
    Write-Host '     The first time, SiteBlock asks you to choose a password.'
    Write-Host '     (If you cannot see the shield, click the small ^ arrow by the clock.)'
    Write-Host '  2. Then run scripts\verify-install.ps1 to check that the block works.'
    Write-Host "Logs: $LogDir"
}

try {
    Install-SiteBlock
    exit 0
} catch {
    Write-Host ''
    Write-Host "SiteBlock was not installed completely: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'It is safe to run the installer again.'
    exit 1
}
