# The end-to-end test of SiteBlock for Windows. GitHub's Windows machine runs it after package.ps1: it unzips
# windows\dist\SiteBlock-Windows.zip into a temp folder, runs that copy's scripts\install.ps1 (a real install, with
# real services, the real hosts file, the real registry and the real network adapters), and then runs every check in
# 06-windows.md, Testing, item 5.
#
#   pwsh windows/scripts/e2e.ps1                      (on GitHub's Windows machine, where the job is administrator)
#
# Each check prints "PASS <name>", "FAIL <name>: <why>" or "SKIP <name>: <why>". A FAIL also prints a GitHub
# annotation line (::error ...), so the failure shows on the run page. At the end it prints a summary, copies
# C:\ProgramData\SiteBlock\Logs into the folder the workflow uploads (windows\dist\e2e-logs), prints the last 50 lines
# of siteblockd.log (the log never holds sites or passwords, by design), and exits 1 when any check failed.
#
# It changes this PC for real: it installs SiteBlock, blocks youtube.com, sets a password and points the network
# adapters at Cloudflare for Families. So it refuses to run outside GitHub Actions unless -AllowOnThisPC is given.
# It runs in Windows PowerShell 5.1 and in PowerShell 7 on Windows.
[CmdletBinding()]
param(
    [string]$ZipPath = '',
    [string]$LogOut = '',
    [switch]$AllowOnThisPC
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WindowsRoot = Split-Path -Parent $PSScriptRoot
if ($ZipPath -eq '') { $ZipPath = Join-Path $WindowsRoot 'dist\SiteBlock-Windows.zip' }
if ($LogOut -eq '') { $LogOut = Join-Path $WindowsRoot 'dist\e2e-logs' }

# Where the installed pieces are (06-windows.md, Installed Paths and Permissions).
$ProgramDir = Join-Path $env:ProgramFiles 'SiteBlock'
$CliExe = Join-Path $ProgramDir 'siteblock.exe'
$DataDir = Join-Path $env:ProgramData 'SiteBlock'
$StateFile = Join-Path $DataDir 'state\state.json'
$LogDir = Join-Path $DataDir 'Logs'
$DaemonLog = Join-Path $LogDir 'siteblockd.log'
$HostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$TcpipParametersKey = 'SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
$WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$TestDomain = 'youtube.com'

# A fresh password for this run, and a wrong one. Letters and digits only, so no console code page can change them.
$Password = 'e2e' + [guid]::NewGuid().ToString('N').Substring(0, 20)
$WrongPassword = 'wrong' + [guid]::NewGuid().ToString('N').Substring(0, 20)

$script:Results = New-Object System.Collections.ArrayList
$script:PackageDir = ''
$script:OriginalDataBasePath = $null
$script:OriginalDataBasePathKind = [Microsoft.Win32.RegistryValueKind]::ExpandString

# ---------------------------------------------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------------------------------------------

# Makes text safe for a GitHub annotation: GitHub reads %, CR and LF (and in the title also : and ,) as control characters.
function ConvertTo-AnnotationText([string]$text, [switch]$Title) {
    $escaped = $text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($Title) { $escaped = $escaped.Replace(':', '%3A').Replace(',', '%2C') }
    return $escaped
}

# Records one check's result and prints its line (plus the GitHub annotation for a failure).
function Add-Result([string]$outcome, [string]$name, [string]$why) {
    [void]$script:Results.Add((New-Object PSObject -Property @{ Outcome = $outcome; Name = $name; Why = $why }))
    switch ($outcome) {
        'PASS' {
            if ($why) { Write-Host "PASS $name ($why)" -ForegroundColor Green } else { Write-Host "PASS $name" -ForegroundColor Green }
        }
        'SKIP' {
            Write-Host "SKIP ${name}: $why" -ForegroundColor Yellow
            # A skip is a notice on the run page too, so it is plain from outside which checks did not run and why.
            Write-Host ('::notice title={0}::{1}' -f (ConvertTo-AnnotationText "e2e skipped: $name" -Title), (ConvertTo-AnnotationText $why))
        }
        'FAIL' {
            Write-Host "FAIL ${name}: $why" -ForegroundColor Red
            Write-Host ('::error title={0}::{1}' -f (ConvertTo-AnnotationText "e2e $name" -Title), (ConvertTo-AnnotationText $why))
        }
    }
}

# Stops the current check and marks it skipped, with the reason.
function Skip-Check([string]$why) {
    throw "SKIP:$why"
}

# Runs one named check. The check passes when its body finishes; it fails with the message of anything it throws,
# and it is skipped when it calls Skip-Check. A string the body returns is printed as a note on the PASS line.
function Invoke-Check([string]$name, [scriptblock]$body) {
    Write-Host ''
    Write-Host "--- $name"
    try {
        $note = & $body
        Add-Result 'PASS' $name ([string]($note | Select-Object -Last 1))
    } catch {
        $message = $_.Exception.Message
        if ($message.StartsWith('SKIP:')) {
            Add-Result 'SKIP' $name $message.Substring(5)
        } else {
            Add-Result 'FAIL' $name $message
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------

# Joins arguments into one command line, quoting the ones that contain spaces.
function Join-Arguments([string[]]$arguments) {
    $parts = foreach ($argument in $arguments) {
        if ($argument -match '[\s"]') { '"' + $argument.Replace('"', '\"') + '"' } else { $argument }
    }
    return ($parts -join ' ')
}

# Runs a program with the given arguments and lines of standard input, waits at most the given seconds, and returns
# its exit code and what it printed on standard output and standard error. A program that runs too long is ended,
# with its child processes, and gets exit code -1.
function Invoke-Program([string]$filePath, [string[]]$arguments, [string[]]$inputLines = @(), [int]$timeoutSeconds = 30) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $filePath
    $info.Arguments = Join-Arguments $arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    # The input is written and then closed, so a program that asks for more lines than were given sees the end and stops.
    foreach ($line in $inputLines) { $process.StandardInput.WriteLine($line) }
    $process.StandardInput.Close()
    $exitCode = -1
    if ($process.WaitForExit($timeoutSeconds * 1000)) {
        $exitCode = $process.ExitCode
    } else {
        Invoke-Program 'taskkill.exe' @('/T', '/F', '/PID', [string]$process.Id) @() 15 | Out-Null
    }
    $stdout = $outTask.Result
    $stderr = $errTask.Result
    return New-Object PSObject -Property @{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr; Text = ($stdout + "`n" + $stderr).Trim() }
}

# Runs the installed siteblock.exe with arguments and optional password lines on standard input.
function Invoke-SiteBlock([string[]]$arguments, [string[]]$inputLines = @()) {
    return (Invoke-Program $CliExe $arguments $inputLines 30)
}

# Waits until the condition is true, checking every 200 milliseconds, for at most the given milliseconds.
# Returns how many milliseconds it took, or -1 when the time ran out.
function Wait-Until([int]$timeoutMs, [scriptblock]$condition) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $ok = $false
        try { $ok = [bool](& $condition) } catch { $ok = $false }
        if ($ok) { return [int]$watch.ElapsedMilliseconds }
        if ($watch.ElapsedMilliseconds -ge $timeoutMs) { return -1 }
        Start-Sleep -Milliseconds 200
    }
}

# Returns the line of "siteblock status" output for a blocked site ("  youtube.com (28 hosts) ..."), or $null.
function Get-SiteLine([string]$statusText, [string]$domain) {
    foreach ($line in ($statusText -split "`r?`n")) {
        if ($line.StartsWith("  $domain (")) { return $line }
    }
    return $null
}

# Runs "siteblock status" and returns its text; throws when it does not answer.
function Get-StatusText {
    $result = Invoke-SiteBlock @('status')
    if ($result.ExitCode -ne 0) { throw "siteblock status exited $($result.ExitCode): $($result.Text)" }
    return $result.StdOut
}

# Waits up to the given seconds for "siteblock status" to answer again (after a service restart).
function Wait-Daemon([int]$seconds) {
    $elapsed = Wait-Until ($seconds * 1000) { (Invoke-SiteBlock @('status')).ExitCode -eq 0 }
    if ($elapsed -lt 0) { throw "siteblock status did not answer within $seconds seconds" }
}

# Returns the service as Windows Management Instrumentation sees it (Name, State, StartMode, ProcessId, PathName), or
# $null when it is not installed. WMI is used instead of Get-Service because a ServiceController keeps a handle open
# to the service, and an open handle stops Windows from really deleting a service, which the watchdog check needs.
function Get-ServiceInfo([string]$name) {
    return (Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'")
}

# Returns the hosts file's lines with spaces trimmed.
function Get-HostsLines {
    return @([System.IO.File]::ReadAllLines($HostsFile) | ForEach-Object { $_.Trim() })
}

# Reads a text file that another program may be writing at the same moment (the service's log), or '' when it is missing.
function Read-SharedText([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } finally {
        $stream.Dispose()
    }
}

# Opens a key under HKEY_LOCAL_MACHINE in the 64-bit registry for reading, or returns $null when it is missing.
function Open-MachineKey([string]$path, [bool]$writable = $false) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    return $base.OpenSubKey($path, $writable)
}

# Throws unless the policy key holds the named value with the wanted registry type and content. A value of the right
# name but the wrong type counts as wrong, because the browsers ignore a policy of the wrong type.
function Assert-PolicyValue([string]$keyPath, [string]$name, [Microsoft.Win32.RegistryValueKind]$kind, $expected) {
    $key = Open-MachineKey $keyPath
    if ($null -eq $key) { throw "HKLM\$keyPath is missing" }
    try {
        if ($key.GetValueNames() -notcontains $name) { throw "HKLM\$keyPath has no value $name" }
        $actualKind = $key.GetValueKind($name)
        if ($actualKind -ne $kind) { throw "HKLM\$keyPath\$name is a $actualKind value, not $kind" }
        $actual = $key.GetValue($name)
        if ([string]$actual -ne [string]$expected) { throw "HKLM\$keyPath\$name is '$actual', not '$expected'" }
    } finally {
        $key.Close()
    }
}

# Throws unless the list key's values are named 1, 2, 3 ... with no gap, are all strings, and include the entry.
function Assert-PolicyList([string]$keyPath, [string]$entry) {
    $key = Open-MachineKey $keyPath
    if ($null -eq $key) { throw "HKLM\$keyPath is missing" }
    try {
        $names = @($key.GetValueNames() | Where-Object { $_ -ne '' })
        if ($names.Count -eq 0) { throw "HKLM\$keyPath has no entries" }
        $numbers = @($names | ForEach-Object {
                if ($_ -notmatch '^[1-9][0-9]*$') { throw "HKLM\$keyPath has a value named '$_', and every name must be a number" }
                [int]$_
            } | Sort-Object)
        for ($i = 0; $i -lt $numbers.Count; $i++) {
            if ($numbers[$i] -ne $i + 1) { throw "HKLM\$keyPath values are not numbered 1 to $($numbers.Count) without a gap" }
        }
        $values = foreach ($name in $names) {
            if ($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::String) { throw "HKLM\$keyPath\$name is not a string value" }
            [string]$key.GetValue($name)
        }
        if (@($values) -notcontains $entry) { throw "HKLM\$keyPath does not hold $entry" }
    } finally {
        $key.Close()
    }
}

# Returns the ID of the session shown on the PC's own screen (the console session).
function Get-ConsoleSessionId {
    if (-not ('SiteBlockE2E.Session' -as [type])) {
        Add-Type -Namespace SiteBlockE2E -Name Session -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();'
    }
    return [int][SiteBlockE2E.Session]::WTSGetActiveConsoleSessionId()
}

# Runs the unzipped package's install.ps1 with Windows PowerShell 5.1, the way a person's PC runs it, saves its
# output under the given log name, prints it, and throws when it fails.
function Invoke-Installer([string]$logName) {
    $installer = Join-Path $script:PackageDir 'scripts\install.ps1'
    $result = Invoke-Program $WindowsPowerShell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer) @() 300
    [System.IO.File]::WriteAllText((Join-Path $LogOut $logName), $result.Text)
    foreach ($line in ($result.Text -split "`r?`n")) { Write-Host "    $line" }
    if ($result.ExitCode -ne 0) { throw "install.ps1 exited $($result.ExitCode) (its output is above and in $logName)" }
}

# Puts DataBasePath back to the value it had before the test, in case the service did not.
function Restore-DataBasePath {
    if ($null -eq $script:OriginalDataBasePath) { return }
    $key = Open-MachineKey $TcpipParametersKey $true
    try {
        $current = [string]$key.GetValue('DataBasePath', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($current -ne $script:OriginalDataBasePath) { $key.SetValue('DataBasePath', $script:OriginalDataBasePath, $script:OriginalDataBasePathKind) }
    } finally {
        $key.Close()
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Checks (06-windows.md, Testing, item 5)
# ---------------------------------------------------------------------------------------------------------------

# Unzips the package into a fresh temp folder and checks it holds the installer and this PC's three programs.
function Test-PackageUnzips {
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "$ZipPath does not exist; run package.ps1 first" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $target = Join-Path ([System.IO.Path]::GetTempPath()) ('siteblock-e2e-' + [guid]::NewGuid().ToString('N'))
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $target)
    $script:PackageDir = Join-Path $target 'SiteBlock'
    $arch = 'x64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
    $needed = @('scripts\install.ps1', 'scripts\verify-install.ps1', 'Install SiteBlock.cmd', 'INSTALL.txt', "bin\$arch\siteblockd.exe", "bin\$arch\siteblock.exe", "bin\$arch\SiteBlockApp.exe")
    foreach ($relative in $needed) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:PackageDir $relative) -PathType Leaf)) { throw "the unzipped package has no $relative" }
    }
    return "unzipped to $target"
}

# Both services are installed, set to start automatically and running.
function Test-ServicesRunning {
    foreach ($name in @('SiteBlock', 'SiteBlockWatchdog')) {
        $service = Get-ServiceInfo $name
        if ($null -eq $service) { throw "the $name service is not installed" }
        if ($service.State -ne 'Running') { throw "the $name service is $($service.State), not Running" }
        if ($service.StartMode -ne 'Auto') { throw "the $name service starts $($service.StartMode), not Auto" }
    }
}

# "siteblock status" answers with a status.
function Test-StatusAnswers {
    $text = Get-StatusText
    if ($text -notmatch 'SiteBlock') { throw "siteblock status answered, but not with a status: $text" }
}

# "siteblock add youtube.com" with a new password piped in (asked twice, because no password is set yet) works.
function Test-AddSite {
    $result = Invoke-SiteBlock @('add', $TestDomain) @($Password, $Password)
    if ($result.ExitCode -ne 0) { throw "siteblock add exited $($result.ExitCode): $($result.Text)" }
    if ($null -eq (Get-SiteLine (Get-StatusText) $TestDomain)) { throw "siteblock status does not list $TestDomain after the add" }
}

# The real hosts file blocks the site under its common names.
function Test-HostsLines {
    $wanted = @("0.0.0.0 $TestDomain", "0.0.0.0 www.$TestDomain", "0.0.0.0 m.$TestDomain", '0.0.0.0 youtu.be', ":: $TestDomain")
    $elapsed = Wait-Until 5000 {
        $lines = Get-HostsLines
        @($wanted | Where-Object { $lines -notcontains $_ }).Count -eq 0
    }
    if ($elapsed -lt 0) {
        $lines = Get-HostsLines
        $missing = @($wanted | Where-Object { $lines -notcontains $_ })
        throw "the hosts file is missing: $($missing -join '; ')"
    }
}

# The Windows name lookup returns 0.0.0.0 for www.youtube.com.
function Test-Lookup {
    $script:LastLookup = ''
    $elapsed = Wait-Until 5000 {
        $addresses = @([System.Net.Dns]::GetHostAddresses("www.$TestDomain") | ForEach-Object { $_.ToString() })
        $script:LastLookup = $addresses -join ', '
        $addresses.Count -gt 0 -and @($addresses | Where-Object { $_ -ne '0.0.0.0' -and $_ -ne '::' }).Count -eq 0
    }
    if ($elapsed -lt 0) { throw "www.$TestDomain resolves to '$($script:LastLookup)', not 0.0.0.0" }
    return "resolves to $($script:LastLookup)"
}

# Chrome's policy key holds the adult-filter values and a block list with the site.
function Test-ChromePolicy {
    $key = 'SOFTWARE\Policies\Google\Chrome'
    Assert-PolicyValue $key 'SafeSitesFilterBehavior' DWord 1
    Assert-PolicyValue $key 'ForceGoogleSafeSearch' DWord 1
    Assert-PolicyValue $key 'DnsOverHttpsMode' String 'off'
    Assert-PolicyList "$key\URLBlocklist" $TestDomain
}

# Edge's policy key holds the adult-filter values and a block list with the site.
function Test-EdgePolicy {
    $key = 'SOFTWARE\Policies\Microsoft\Edge'
    Assert-PolicyValue $key 'DnsOverHttpsMode' String 'off'
    Assert-PolicyValue $key 'ForceGoogleSafeSearch' DWord 1
    Assert-PolicyValue $key 'ForceBingSafeSearch' DWord 2
    Assert-PolicyList "$key\URLBlocklist" $TestDomain
}

# Brave's policy key holds the adult-filter values and a block list with the site.
function Test-BravePolicy {
    $key = 'SOFTWARE\Policies\BraveSoftware\Brave'
    Assert-PolicyValue $key 'DnsOverHttpsMode' String 'off'
    Assert-PolicyValue $key 'SafeSitesFilterBehavior' DWord 1
    Assert-PolicyValue $key 'ForceGoogleSafeSearch' DWord 1
    Assert-PolicyList "$key\URLBlocklist" $TestDomain
}

# Firefox's policy key turns its own DNS-over-HTTPS off (locked) and blocks the site with a match pattern.
function Test-FirefoxPolicy {
    $key = 'SOFTWARE\Policies\Mozilla\Firefox'
    Assert-PolicyValue "$key\DNSOverHTTPS" 'Enabled' DWord 0
    Assert-PolicyValue "$key\DNSOverHTTPS" 'Locked' DWord 1
    Assert-PolicyList "$key\WebsiteFilter\Block" "*://*.$TestDomain/*"
}

# Chrome, started headless with a fresh profile, refuses https://www.youtube.com/ with its "blocked by your
# administrator" error. Chrome reads the registry policy when it starts. With --dump-dom it prints the page it ended
# on, which for a blocked address is its error page, holding the error code ERR_BLOCKED_BY_ADMINISTRATOR.
function Test-ChromeRefusesSite {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    $chrome = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -eq $chrome) { Skip-Check 'Chrome is not installed on this machine' }
    $chromeProfile = Join-Path ([System.IO.Path]::GetTempPath()) ('siteblock-chrome-' + [guid]::NewGuid().ToString('N'))
    $arguments = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--enable-logging=stderr', '--v=0', "--user-data-dir=$chromeProfile", '--dump-dom', "https://www.$TestDomain/")
    $result = Invoke-Program $chrome $arguments @() 30
    [System.IO.File]::WriteAllText((Join-Path $LogOut 'chrome-dump-dom.txt'), $result.Text)
    if ($result.Text -match 'ERR_BLOCKED_BY_ADMINISTRATOR') { return 'Chrome showed ERR_BLOCKED_BY_ADMINISTRATOR' }
    if ($result.Text -match 'is blocked' -and $result.Text -match 'administrator|organi[sz]ation') { return 'Chrome showed its blocked-by-your-organization page' }
    if ($result.ExitCode -eq -1) { throw 'Chrome did not finish within 30 seconds (its output is in chrome-dump-dom.txt)' }
    $sample = ($result.Text -replace '\s+', ' ')
    if ($sample.Length -gt 300) { $sample = $sample.Substring(0, 300) }
    throw "Chrome did not show ERR_BLOCKED_BY_ADMINISTRATOR; its output begins: $sample"
}

# The packaged verify-install.ps1 passes on this install (youtube.com is blocked now, so all of its checks run).
function Test-VerifyInstallScript {
    $verifyScript = Join-Path $script:PackageDir 'scripts\verify-install.ps1'
    $result = Invoke-Program $WindowsPowerShell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifyScript) @() 120
    [System.IO.File]::WriteAllText((Join-Path $LogOut 'verify-install.log'), $result.Text)
    foreach ($line in ($result.Text -split "`r?`n")) { Write-Host "    $line" }
    if ($result.ExitCode -ne 0) { throw "verify-install.ps1 exited $($result.ExitCode) (its FAIL lines are above)" }
}

# Every Ethernet and Wi-Fi adapter that is up (except VPN adapters) uses the family DNS servers, or the service logged
# that the family servers cannot be reached from this network and kept the network's own servers.
function Test-FamilyDns {
    $vpnWords = @('VPN', 'TAP-Windows', 'WireGuard', 'Wintun', 'OpenVPN', 'Tailscale', 'ZeroTier', 'AnyConnect', 'Fortinet', 'GlobalProtect', 'Cloudflare WARP')
    $script:DnsProblem = ''
    # Lists the adapters the service is meant to change, read fresh each time.
    $listAdapters = {
        @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
                $adapter = $_
                $adapter.OperationalStatus -eq 'Up' -and
                ($adapter.NetworkInterfaceType -eq 'Ethernet' -or $adapter.NetworkInterfaceType -eq 'Wireless80211') -and
                @($vpnWords | Where-Object { $adapter.Description.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -eq 0
            })
    }
    if (@(& $listAdapters).Count -eq 0) { Skip-Check 'this machine has no Ethernet or Wi-Fi adapter that is up' }
    $script:DnsOutcome = ''
    $elapsed = Wait-Until 40000 {
        if ((Read-SharedText $DaemonLog) -match 'family DNS unreachable') {
            $script:DnsOutcome = 'the family servers are unreachable here; the service logged "family DNS unreachable"'
            return $true
        }
        $wrong = @()
        foreach ($adapter in (& $listAdapters)) {
            $servers = @($adapter.GetIPProperties().DnsAddresses | ForEach-Object { $_.ToString() })
            if (($servers -notcontains '1.1.1.3') -or ($servers -notcontains '1.0.0.3')) { $wrong += "$($adapter.Name) uses $($servers -join ', ')" }
        }
        $script:DnsProblem = $wrong -join '; '
        if ($wrong.Count -eq 0) { $script:DnsOutcome = 'every adapter uses 1.1.1.3 and 1.0.0.3' }
        return ($wrong.Count -eq 0)
    }
    if ($elapsed -lt 0) { throw "after 40 seconds: $($script:DnsProblem), and the log does not say ""family DNS unreachable""" }
    return $script:DnsOutcome
}

# Returns the number in "N tries left" (or "1 try left") from a wrong-password answer, or -1 when it has none.
function Get-TriesLeft([string]$text) {
    if ($text -match '(\d+) tr(y|ies) left') { return [int]$Matches[1] }
    return -1
}

# A wrong password is refused with exit code 1 and the "Wrong password" answer.
function Test-WrongPasswordRefused {
    $result = Invoke-SiteBlock @('unblock', $TestDomain) @($WrongPassword)
    if ($result.ExitCode -ne 1) { throw "siteblock unblock with a wrong password exited $($result.ExitCode), not 1: $($result.Text)" }
    if ($result.Text -notmatch 'Wrong password') { throw "the answer does not say Wrong password: $($result.Text)" }
    $script:TriesLeftAfterFirstWrong = Get-TriesLeft $result.Text
}

# A temporary unblock whose start wait (1 minute) is shorter than the unblock delay (30 minutes) is refused before the
# password is checked, so it never counts as a wrong password. The six requests use the WRONG password on purpose:
# if they were checked against the password first, they would count as wrong passwords and lock password checks
# (five wrong passwords lock them), and the next wrong-password answer would show fewer tries left.
function Test-ShortTemporaryUnblockNotCounted {
    for ($i = 1; $i -le 6; $i++) {
        $result = Invoke-SiteBlock @('unblock', $TestDomain, '--for', '30m', '--in', '1m') @($WrongPassword)
        if ($result.ExitCode -ne 1) { throw "request $i exited $($result.ExitCode), not 1: $($result.Text)" }
        if ($result.Text -match 'Wrong password|Too many wrong passwords|checks are locked') { throw "request $i was checked against the password: $($result.Text)" }
    }
    $again = Invoke-SiteBlock @('unblock', $TestDomain) @($WrongPassword)
    if ($again.Text -match 'Too many wrong passwords|checks are locked') { throw "password checks are locked after the short requests: $($again.Text)" }
    $left = Get-TriesLeft $again.Text
    if ($script:TriesLeftAfterFirstWrong -ge 0 -and $left -ge 0 -and $left -ne $script:TriesLeftAfterFirstWrong - 1) {
        throw "the second wrong password left $left tries, but $($script:TriesLeftAfterFirstWrong - 1) were expected, so the short requests were counted"
    }
    return "six refused; tries left went from $($script:TriesLeftAfterFirstWrong) to $left"
}

# The right password still works (no lockout): an unblock starts its countdown, and cancel ends it again.
function Test-UnblockAndCancel {
    $result = Invoke-SiteBlock @('unblock', $TestDomain) @($Password)
    if ($result.ExitCode -ne 0) { throw "siteblock unblock with the right password exited $($result.ExitCode): $($result.Text)" }
    $line = Get-SiteLine (Get-StatusText) $TestDomain
    if ($null -eq $line -or $line -notmatch 'unblocks in') { throw "siteblock status does not show the unblock countdown: '$line'" }
    $cancel = Invoke-SiteBlock @('cancel', $TestDomain)
    if ($cancel.ExitCode -ne 0) { throw "siteblock cancel exited $($cancel.ExitCode): $($cancel.Text)" }
    $line = Get-SiteLine (Get-StatusText) $TestDomain
    if ($null -eq $line) { throw "$TestDomain is no longer listed after cancel" }
    if ($line -match 'unblocks in') { throw "the countdown is still shown after cancel: '$line'" }
}

# Removing SiteBlock's section from the hosts file by hand is undone within 3 seconds.
function Test-HostsSectionRepaired {
    $text = [System.IO.File]::ReadAllText($HostsFile)
    $pattern = '(?ms)^# BEGIN SiteBlock.*?^# END SiteBlock[^\n]*\n?'
    if ($text -notmatch $pattern) { throw 'the hosts file has no SiteBlock section to remove' }
    $stripped = [regex]::Replace($text, $pattern, '')
    # The service may mark the file read-only; an administrator can clear that, as a person tampering would.
    [System.IO.File]::SetAttributes($HostsFile, [System.IO.FileAttributes]::Normal)
    [System.IO.File]::WriteAllText($HostsFile, $stripped)
    $elapsed = Wait-Until 3000 { (Get-HostsLines) -contains "0.0.0.0 $TestDomain" }
    if ($elapsed -lt 0) { throw 'the hosts section was not put back within 3 seconds' }
    return "put back after $elapsed ms"
}

# Pointing DataBasePath (the folder Windows reads the hosts file from) somewhere else is undone within 3 seconds.
function Test-DataBasePathRepaired {
    $key = Open-MachineKey $TcpipParametersKey $true
    if ($null -eq $key) { throw "HKLM\$TcpipParametersKey is missing" }
    try {
        $script:OriginalDataBasePath = [string]$key.GetValue('DataBasePath', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($key.GetValueNames() -contains 'DataBasePath') { $script:OriginalDataBasePathKind = $key.GetValueKind('DataBasePath') }
        $key.SetValue('DataBasePath', 'C:\Windows\Temp', [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        $key.Close()
    }
    $wanted = (Join-Path $env:SystemRoot 'System32\drivers\etc').TrimEnd('\')
    $elapsed = Wait-Until 3000 {
        $check = Open-MachineKey $TcpipParametersKey
        try { ([Environment]::ExpandEnvironmentVariables([string]$check.GetValue('DataBasePath', ''))).TrimEnd('\') -ieq $wanted } finally { $check.Close() }
    }
    if ($elapsed -lt 0) { throw "DataBasePath was not reset to $wanted within 3 seconds" }
    return "reset after $elapsed ms"
}

# Deleting state.json is undone within 3 seconds, and the blocks are kept.
function Test-StateFileRestored {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { throw "$StateFile does not exist before the test" }
    Remove-Item -LiteralPath $StateFile -Force
    $elapsed = Wait-Until 3000 { Test-Path -LiteralPath $StateFile -PathType Leaf }
    if ($elapsed -lt 0) { throw 'state.json was not written again within 3 seconds' }
    if ($null -eq (Get-SiteLine (Get-StatusText) $TestDomain)) { throw "$TestDomain is no longer blocked after state.json was deleted" }
    return "written again after $elapsed ms"
}

# Stopping the SiteBlock service is undone within 10 seconds: it runs again, as a new process (a new process ID proves
# it really stopped and was started again).
function Test-StoppedServiceRestarted {
    $before = (Get-ServiceInfo 'SiteBlock').ProcessId
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    # sc.exe only sends the stop request; Stop-Service would wait without a time limit if the stop never finished.
    $stop = Invoke-Program 'sc.exe' @('stop', 'SiteBlock') @() 15
    if ($stop.ExitCode -ne 0) { throw "sc.exe stop exited $($stop.ExitCode): $($stop.Text)" }
    $remaining = [Math]::Max(0, 10000 - [int]$watch.ElapsedMilliseconds)
    $elapsed = Wait-Until $remaining {
        $service = Get-ServiceInfo 'SiteBlock'
        $null -ne $service -and $service.State -eq 'Running' -and $service.ProcessId -ne 0 -and $service.ProcessId -ne $before
    }
    if ($elapsed -lt 0) { throw "the SiteBlock service was not running again within 10 seconds (state: $((Get-ServiceInfo 'SiteBlock').State))" }
    $total = [int]$watch.ElapsedMilliseconds
    Wait-Daemon 10
    return "running again after $total ms"
}

# Setting the SiteBlock service to Disabled is undone within 10 seconds (its start type is Automatic again).
function Test-DisabledServiceRepaired {
    $result = Invoke-Program 'sc.exe' @('config', 'SiteBlock', 'start=', 'disabled') @() 15
    if ($result.ExitCode -ne 0) { throw "sc.exe config exited $($result.ExitCode): $($result.Text)" }
    $elapsed = Wait-Until 10000 {
        $key = Open-MachineKey 'SYSTEM\CurrentControlSet\Services\SiteBlock'
        try { [int]$key.GetValue('Start', 4) -eq 2 } finally { $key.Close() }
    }
    if ($elapsed -lt 0) { throw 'the SiteBlock service was still not set to start automatically after 10 seconds' }
    if ((Get-ServiceInfo 'SiteBlock').State -ne 'Running') { throw 'the start type was repaired, but the service is not running' }
    return "Automatic again after $elapsed ms"
}

# Deleting the SiteBlockWatchdog service is undone within 15 seconds: the SiteBlock service recreates it and starts it.
function Test-DeletedWatchdogRecreated {
    $before = Get-ServiceInfo 'SiteBlockWatchdog'
    if ($null -eq $before) { throw 'the SiteBlockWatchdog service is not installed before the test' }
    Invoke-Program 'sc.exe' @('stop', 'SiteBlockWatchdog') @() 15 | Out-Null
    $stopped = Wait-Until 10000 { (Get-ServiceInfo 'SiteBlockWatchdog').State -eq 'Stopped' }
    if ($stopped -lt 0) { Write-Host '    the watchdog did not report Stopped within 10 seconds; deleting it anyway' }
    $delete = Invoke-Program 'sc.exe' @('delete', 'SiteBlockWatchdog') @() 15
    if ($delete.ExitCode -ne 0) { throw "sc.exe delete exited $($delete.ExitCode): $($delete.Text)" }
    $elapsed = Wait-Until 15000 {
        $service = Get-ServiceInfo 'SiteBlockWatchdog'
        $null -ne $service -and $service.State -eq 'Running' -and $service.ProcessId -ne $before.ProcessId
    }
    if ($elapsed -lt 0) { throw 'the SiteBlockWatchdog service was not back and running within 15 seconds' }
    $after = Get-ServiceInfo 'SiteBlockWatchdog'
    if ($after.StartMode -ne 'Auto') { throw "the recreated watchdog starts $($after.StartMode), not Auto" }
    if ($after.PathName -notmatch '--watchdog') { throw "the recreated watchdog runs '$($after.PathName)', without --watchdog" }
    return "recreated and running after $elapsed ms"
}

# When someone is signed in at the PC's screen, the tray app runs in that session, and it is started again within
# 10 seconds after it is stopped.
function Test-TrayApp {
    $user = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if ([string]::IsNullOrEmpty($user)) { Skip-Check 'nobody is signed in at the console of this machine' }
    $session = Get-ConsoleSessionId
    # Lists the tray app processes in the console session.
    $inSession = { @(Get-Process -Name 'SiteBlockApp' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }) }
    $first = Wait-Until 15000 { (& $inSession).Count -gt 0 }
    if ($first -lt 0) { throw "no SiteBlockApp process started in the console session ($session, user $user) within 15 seconds" }
    $old = @(& $inSession | ForEach-Object { $_.Id })
    $old | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
    $elapsed = Wait-Until 10000 { @(& $inSession | Where-Object { $old -notcontains $_.Id }).Count -gt 0 }
    if ($elapsed -lt 0) { throw 'the tray app was not started again within 10 seconds after it was stopped' }
    return "running for $user; started again after $elapsed ms"
}

# A second run of install.ps1 (an upgrade) keeps the blocks, the password and a running countdown.
function Test-UpgradeKeepsState {
    $unblock = Invoke-SiteBlock @('unblock', $TestDomain) @($Password)
    if ($unblock.ExitCode -ne 0) { throw "starting an unblock before the upgrade failed ($($unblock.ExitCode)): $($unblock.Text)" }
    Invoke-Installer 'install-2-upgrade.log'
    $line = Get-SiteLine (Get-StatusText) $TestDomain
    if ($null -eq $line) { throw "$TestDomain is no longer blocked after the upgrade" }
    if ($line -notmatch 'unblocks in') { throw "the unblock countdown was lost in the upgrade: '$line'" }
    $cancel = Invoke-SiteBlock @('cancel', $TestDomain)
    if ($cancel.ExitCode -ne 0) { throw "siteblock cancel after the upgrade exited $($cancel.ExitCode): $($cancel.Text)" }
    $again = Invoke-SiteBlock @('unblock', $TestDomain) @($Password)
    if ($again.ExitCode -ne 0) { throw "the password no longer works after the upgrade ($($again.ExitCode)): $($again.Text)" }
    $cancelAgain = Invoke-SiteBlock @('cancel', $TestDomain)
    if ($cancelAgain.ExitCode -ne 0) { throw "the final siteblock cancel exited $($cancelAgain.ExitCode): $($cancelAgain.Text)" }
}

# Returns the path of chrome.exe, or $null when Chrome is not installed.
function Find-Chrome {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    return $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

# Runs one JavaScript expression in a Chrome tab through the DevTools protocol (the websocket Chrome opens with
# --remote-debugging-port) and returns its value as text, or $null when it gives no value.
function Invoke-TabScript([string]$webSocketUrl, [string]$expression) {
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $limit = New-Object System.Threading.CancellationTokenSource 10000
    try {
        $socket.ConnectAsync([Uri]$webSocketUrl, $limit.Token).GetAwaiter().GetResult()
        $request = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = $expression; returnByValue = $true } } | ConvertTo-Json -Compress -Depth 5
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($request)
        $socket.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $limit.Token).GetAwaiter().GetResult()
        # Chrome may send other messages first; the answer is the one carrying id 1.
        while ($true) {
            $text = New-Object System.Text.StringBuilder
            $buffer = New-Object byte[] 65536
            do {
                $received = $socket.ReceiveAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)), $limit.Token).GetAwaiter().GetResult()
                [void]$text.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $received.Count))
            } while (-not $received.EndOfMessage)
            $answer = $text.ToString() | ConvertFrom-Json
            if ($answer.PSObject.Properties['id'] -and $answer.id -eq 1) {
                $value = $answer.result.result.PSObject.Properties['value']
                if ($null -eq $value) { return $null }
                return [string]$value.Value
            }
        }
    } finally {
        $socket.Dispose()
        $limit.Dispose()
    }
}

# Returns Chrome's open tabs (type "page") from its DevTools list.
function Get-ChromeTabs([int]$port) {
    return @(Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 5 | Where-Object { $_.type -eq 'page' })
}

# Counts the tray app's "reloaded a tab" lines in its log (the log of the person signed in at the screen, who is also
# the account running this script when the check runs at all).
function Get-TabReloadCount {
    $appLog = Join-Path $env:LOCALAPPDATA 'SiteBlock\Logs\app.log'
    $text = Read-SharedText $appLog
    return @([regex]::Matches($text, 'reloaded a Google Chrome tab on a blocked part of a site')).Count
}

# 06-windows.md, Testing, item 6. The tray app reads each Chrome window's address bar through UI Automation, which
# works only for windows on the same desktop, so the check runs only when this script itself runs in the console
# session where the tray app runs (an interactive desktop), and is skipped otherwise. It blocks a path of
# example.com, opens two visible Chrome windows on ordinary pages of that site, marks both pages, moves the first one
# onto the blocked path with history.pushState (no page load), and checks that the tray app reloaded that tab (its
# mark is gone) exactly once, while the second window's page was left alone (its mark is still there).
function Test-LiveTabWatcher {
    $chrome = Find-Chrome
    if ($null -eq $chrome) { Skip-Check 'Chrome is not installed on this machine' }
    $session = Get-ConsoleSessionId
    if ((Get-Process -Id $PID).SessionId -ne $session) { Skip-Check "this script does not run on the interactive desktop (it is in session $((Get-Process -Id $PID).SessionId), the console is session $session)" }
    if (@(Get-Process -Name 'SiteBlockApp' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }).Count -eq 0) { Skip-Check 'the tray app is not running on the interactive desktop' }

    $rule = 'example.com/sbtabtest'
    $add = Invoke-SiteBlock @('add', $rule)
    if ($add.ExitCode -ne 0) { throw "siteblock add $rule exited $($add.ExitCode): $($add.Text)" }

    $port = 9333
    $chromeProfile = Join-Path ([System.IO.Path]::GetTempPath()) ('siteblock-tabs-' + [guid]::NewGuid().ToString('N'))
    $common = @("--remote-debugging-port=$port", "--user-data-dir=$chromeProfile", '--no-first-run', '--no-default-browser-check')
    $first = Start-Process -FilePath $chrome -ArgumentList ($common + @('--new-window', 'https://example.com/')) -PassThru
    try {
        if ((Wait-Until 20000 { try { @(Get-ChromeTabs $port).Count -ge 1 } catch { $false } }) -lt 0) { throw 'Chrome did not open its debugging port within 20 seconds' }
        # A second launch with the same profile opens a second window in the running Chrome.
        Start-Process -FilePath $chrome -ArgumentList ($common + @('--new-window', 'https://example.com/?stay')) | Out-Null
        if ((Wait-Until 20000 { @(Get-ChromeTabs $port | Where-Object { $_.url -like '*example.com/?stay*' }).Count -ge 1 }) -lt 0) { throw 'the second Chrome window did not open within 20 seconds' }
        $tabs = Get-ChromeTabs $port
        $moving = $tabs | Where-Object { $_.url -eq 'https://example.com/' } | Select-Object -First 1
        $staying = $tabs | Where-Object { $_.url -like '*example.com/?stay*' } | Select-Object -First 1
        if ($null -eq $moving) { throw 'the first window is not on https://example.com/' }
        # The pages must have finished loading before they are marked, or the load would wipe the mark.
        foreach ($tab in @($moving, $staying)) {
            if ((Wait-Until 20000 { (Invoke-TabScript $tab.webSocketDebuggerUrl 'document.readyState') -eq 'complete' }) -lt 0) { throw "a page did not finish loading within 20 seconds ($($tab.url))" }
            [void](Invoke-TabScript $tab.webSocketDebuggerUrl "window.__siteblockMark = 'marked'; 'ok'")
        }
        $before = Get-TabReloadCount
        # The tray app reads the rule list on its next status poll, every 30 seconds while its panel is closed, so the wait allows for that.
        [void](Invoke-TabScript $moving.webSocketDebuggerUrl "history.pushState({}, '', '/sbtabtest/clip'); location.href")
        $elapsed = Wait-Until 45000 { (Invoke-TabScript $moving.webSocketDebuggerUrl "typeof window.__siteblockMark") -eq 'undefined' }
        if ($elapsed -lt 0) { throw 'the tab that moved onto the blocked path was not reloaded within 45 seconds' }
        # A few more watcher ticks must not reload it again.
        Start-Sleep -Seconds 3
        $reloads = (Get-TabReloadCount) - $before
        if ($reloads -ne 1) { throw "the tray app logged $reloads reloads, not exactly one" }
        $stayMark = Invoke-TabScript $staying.webSocketDebuggerUrl 'window.__siteblockMark'
        if ($stayMark -ne 'marked') { throw 'the second window, which never left an allowed page, was reloaded too' }
        return "reloaded once after $elapsed ms; the other window was left alone"
    } finally {
        Get-Process -Name 'chrome' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $chrome -and $_.StartTime -ge $first.StartTime } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# Serves files from a folder on http://127.0.0.1:<port>/ in a background job, for the live update test. Returns the job.
function Start-TestServer([string]$folder, [int]$port) {
    return Start-Job -ArgumentList $folder, $port -ScriptBlock {
        param($folder, $port)
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$port/")
        $listener.Start()
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $path = Join-Path $folder ($context.Request.Url.AbsolutePath.TrimStart('/') -replace '/', '\')
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $bytes = [System.IO.File]::ReadAllBytes($path)
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $context.Response.StatusCode = 404
            }
            $context.Response.Close()
        }
    }
}

# Runs the update probe (a test build of the tray app's updater) and returns its printed results as a hashtable.
function Invoke-UpdateProbe([string]$probe, [string]$versionUrl, [string]$packageUrl, [int]$installedBuild) {
    $result = Invoke-Program $probe @($versionUrl, $packageUrl, [string]$installedBuild) @() 900
    $values = @{ ExitCode = $result.ExitCode; Text = $result.Text }
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ($line -match '^(\w+) ?(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

# 06-windows.md, Testing, item 7. Builds the update probe (the tray app's real updater, downloader and elevated runner,
# pointed at addresses given on its command line), serves this run's package from a local test server under a version
# file that claims a newer build, and checks three paths: a version file with a wrong checksum downloads the package
# but installs nothing; a correct one installs it (the UAC prompt is replaced by this job's administrator rights, so
# the "runas" start goes straight through); and afterwards the service answers with the blocks, password and
# countdown state kept. It also checks that the probe left no download folder behind.
function Test-LiveUpdate {
    $versionFile = Join-Path $WindowsRoot 'dist\version-windows.json'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { throw "$versionFile does not exist; run package.ps1 first" }
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $dotnet) { Skip-Check 'the .NET SDK is not on this machine, so the update probe cannot be built' }

    $probeOut = Join-Path ([System.IO.Path]::GetTempPath()) ('siteblock-probe-' + [guid]::NewGuid().ToString('N'))
    $build = Invoke-Program $dotnet.Source @('build', (Join-Path $WindowsRoot 'tests\SiteBlock.UpdateProbe\SiteBlock.UpdateProbe.csproj'), '-c', 'Release', '-o', $probeOut, '-nologo') @() 600
    [System.IO.File]::WriteAllText((Join-Path $LogOut 'update-probe-build.log'), $build.Text)
    if ($build.ExitCode -ne 0) { throw "building the update probe failed (output in update-probe-build.log)" }
    $probe = Join-Path $probeOut 'SiteBlock.UpdateProbe.exe'

    # The installed build number, read from the installed service.
    $versionText = (Invoke-Program (Join-Path $ProgramDir 'siteblockd.exe') @('--version') @() 30).Text
    if ($versionText -notmatch '\(build (\d+)\)') { throw "siteblockd --version printed '$versionText'" }
    $installedBuild = [int]$Matches[1]

    # The served files: this run's package, and two version files that offer it as a much newer build.
    $served = Join-Path ([System.IO.Path]::GetTempPath()) ('siteblock-served-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $served 'good'), (Join-Path $served 'bad') -Force | Out-Null
    Copy-Item -LiteralPath $ZipPath -Destination (Join-Path $served 'SiteBlock-Windows.zip')
    $info = Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json
    $info.build = $installedBuild + 1000
    $info.version = "1.0.$($info.build)"
    $info | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $served 'good\version-windows.json') -Encoding ASCII
    $info.sha256 = ('0' * 64)
    $info | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $served 'bad\version-windows.json') -Encoding ASCII

    $port = 18765
    $server = Start-TestServer $served $port
    $tempFolders = { @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'SiteBlockUpdate-*' -ErrorAction SilentlyContinue).Count }
    try {
        if ((Wait-Until 15000 { try { (Invoke-WebRequest -Uri "http://127.0.0.1:$port/good/version-windows.json" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { $false } }) -lt 0) { throw 'the local test server did not start' }
        $package = "http://127.0.0.1:$port/SiteBlock-Windows.zip"
        $foldersBefore = & $tempFolders

        # The checksum failure path: the update is offered, downloaded, refused, and nothing is installed.
        $bad = Invoke-UpdateProbe $probe "http://127.0.0.1:$port/bad/version-windows.json" $package $installedBuild
        if ($bad['available'] -ne [string]($installedBuild + 1000)) { throw "the probe did not see the offered build ($($bad.Text))" }
        if ($bad['phase'] -ne 'Failed' -or $bad['failure'] -ne "The update didn't pass its checks, so nothing was installed.") { throw "a wrong checksum ended as '$($bad['phase'])' / '$($bad['failure'])'" }
        if ((& $tempFolders) -ne $foldersBefore) { throw 'the failed update left its download folder behind' }

        # The install path: the same package with its real checksum installs, and the service keeps its state.
        $good = Invoke-UpdateProbe $probe "http://127.0.0.1:$port/good/version-windows.json" $package $installedBuild
        if ($good['phase'] -ne 'Idle' -or $good['stillAvailable'] -ne 'False' -or $good['failure'] -ne '') { throw "the install ended as '$($good['phase'])' / '$($good['failure'])' / notice '$($good['notice'])' (update.log is in the logs)" }
        Wait-Daemon 30
        if ($null -eq (Get-SiteLine (Get-StatusText) $TestDomain)) { throw "$TestDomain is no longer blocked after the update" }
        $check = Invoke-SiteBlock @('unblock', $TestDomain) @($Password)
        if ($check.ExitCode -ne 0) { throw "the password no longer works after the update ($($check.ExitCode)): $($check.Text)" }
        [void](Invoke-SiteBlock @('cancel', $TestDomain))
        return "checksum failure refused; install of build $($installedBuild + 1000) completed and kept the state"
    } finally {
        Stop-Job -Job $server -ErrorAction SilentlyContinue
        Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------

# Copies the service's logs into the uploaded folder and prints the end of siteblockd.log.
function Save-Logs {
    try {
        if (Test-Path -LiteralPath $LogDir) {
            Copy-Item -Path (Join-Path $LogDir '*') -Destination $LogOut -Recurse -Force -ErrorAction Continue
        }
    } catch {
        Write-Host "note: could not copy the logs: $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host '--- last 50 lines of siteblockd.log'
    $text = ''
    try { $text = Read-SharedText $DaemonLog } catch { $text = "could not read it: $($_.Exception.Message)" }
    $lines = @($text -split "`r?`n")
    $lines | Select-Object -Last 50 | ForEach-Object { Write-Host "    $_" }
    # When a check failed, the end of each service log also becomes a warning on the run page, because the uploaded logs can only be downloaded by someone
    # logged in to GitHub. The logs never hold a blocked site, a path rule or a password, by design.
    if (@($script:Results | Where-Object { $_.Outcome -eq 'FAIL' }).Count -gt 0) {
        foreach ($log in @($DaemonLog, (Join-Path $LogDir 'watchdog.log'))) {
            $logText = ''
            try { $logText = Read-SharedText $log } catch { continue }
            $tail = (@($logText -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 40) -join ' | '
            if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }
            if ($tail -ne '') { Write-Host ('::warning title={0}::{1}' -f (ConvertTo-AnnotationText "end of $(Split-Path -Leaf $log)" -Title), (ConvertTo-AnnotationText $tail)) }
        }
    }
}

# Prints the totals and every failed check again, and returns the exit code (1 when any check failed).
function Write-Summary {
    $failed = @($script:Results | Where-Object { $_.Outcome -eq 'FAIL' })
    $passed = @($script:Results | Where-Object { $_.Outcome -eq 'PASS' }).Count
    $skipped = @($script:Results | Where-Object { $_.Outcome -eq 'SKIP' }).Count
    Write-Host ''
    Write-Host '=============================================='
    Write-Host "Summary: $passed passed, $($failed.Count) failed, $skipped skipped"
    foreach ($result in $failed) { Write-Host "  FAIL $($result.Name): $($result.Why)" -ForegroundColor Red }
    # The totals as a notice on the run page, so a green run still says how many checks really ran.
    $passedNames = (@($script:Results | Where-Object { $_.Outcome -eq 'PASS' } | ForEach-Object { $_.Name }) -join '; ')
    Write-Host ('::notice title={0}::{1}' -f (ConvertTo-AnnotationText 'e2e summary' -Title), (ConvertTo-AnnotationText "$passed passed, $($failed.Count) failed, $skipped skipped. Passed: $passedNames"))
    if ($failed.Count -gt 0) { return 1 }
    return 0
}

# The guard against running this on a person's own PC by mistake, and the administrator check.
if ($env:GITHUB_ACTIONS -ne 'true' -and -not $AllowOnThisPC) {
    Write-Host 'e2e.ps1 installs SiteBlock on this PC, blocks youtube.com, sets a test password and changes the DNS servers.'
    Write-Host 'It is meant for GitHub''s Windows machine. To run it here anyway, add -AllowOnThisPC.'
    exit 64
}
$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'e2e.ps1 must run as administrator.'
    exit 1
}
New-Item -ItemType Directory -Path $LogOut -Force | Out-Null

try {
    Invoke-Check 'package unzips' { Test-PackageUnzips }
    $installed = $false
    if ($script:PackageDir -ne '') {
        Invoke-Check 'install' { Invoke-Installer 'install-1.log' }
        $installed = (@($script:Results | Where-Object { $_.Name -eq 'install' -and $_.Outcome -eq 'PASS' }).Count -eq 1)
    }
    if (-not $installed) {
        Add-Result 'FAIL' 'remaining checks' 'not run, because the install did not succeed'
    } else {
        Invoke-Check 'services running' { Test-ServicesRunning }
        Invoke-Check 'status answers' { Test-StatusAnswers }
        Invoke-Check 'add youtube.com' { Test-AddSite }
        Invoke-Check 'hosts file blocks youtube.com' { Test-HostsLines }
        Invoke-Check 'lookup gives 0.0.0.0' { Test-Lookup }
        Invoke-Check 'Chrome policy' { Test-ChromePolicy }
        Invoke-Check 'Edge policy' { Test-EdgePolicy }
        Invoke-Check 'Brave policy' { Test-BravePolicy }
        Invoke-Check 'Firefox policy' { Test-FirefoxPolicy }
        Invoke-Check 'Chrome refuses youtube.com' { Test-ChromeRefusesSite }
        Invoke-Check 'verify-install.ps1 passes' { Test-VerifyInstallScript }
        Invoke-Check 'family DNS on every adapter' { Test-FamilyDns }
        $script:TriesLeftAfterFirstWrong = -1
        Invoke-Check 'wrong password refused' { Test-WrongPasswordRefused }
        Invoke-Check 'short temporary unblock not counted' { Test-ShortTemporaryUnblockNotCounted }
        Invoke-Check 'unblock and cancel with the right password' { Test-UnblockAndCancel }
        Invoke-Check 'hosts section repaired' { Test-HostsSectionRepaired }
        Invoke-Check 'DataBasePath repaired' { Test-DataBasePathRepaired }
        Invoke-Check 'state.json restored' { Test-StateFileRestored }
        Invoke-Check 'stopped service restarted' { Test-StoppedServiceRestarted }
        Invoke-Check 'disabled service repaired' { Test-DisabledServiceRepaired }
        Invoke-Check 'deleted watchdog recreated' { Test-DeletedWatchdogRecreated }
        Invoke-Check 'tray app runs and is restarted' { Test-TrayApp }
        Invoke-Check 'upgrade keeps blocks, password and countdowns' { Test-UpgradeKeepsState }
        Invoke-Check 'live tab watcher' { Test-LiveTabWatcher }
        Invoke-Check 'live update' { Test-LiveUpdate }
    }
} finally {
    try { Restore-DataBasePath } catch { Write-Host "note: could not restore DataBasePath: $($_.Exception.Message)" }
    Save-Logs
}
exit (Write-Summary)
