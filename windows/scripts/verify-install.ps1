# Checks an installed SiteBlock for Windows end to end: the two services, the siteblock command, the hosts file, the
# name lookup, a real connection attempt and the browsers' policy settings in the registry.
# "Install SiteBlock.cmd" runs it right after the install; it can also be run by hand at any time:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-install.ps1
#
# It never asks for a SiteBlock password and never blocks anything. It uses youtube.com as the test site, so block
# youtube.com from the shield icon by the clock first. The service checks, the status check and the hosts file
# health check always run. The blocking checks run only when "siteblock status" lists youtube.com; otherwise each
# prints SKIP and says what to do.
#
# Every check runs even when an earlier one fails. Each prints PASS, FAIL or SKIP, and a summary follows. The exit
# code is 1 when any check printed FAIL, otherwise 0. A SKIP never makes the script fail.
# It runs in Windows PowerShell 5.1, the version every Windows 10 and 11 PC has.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The test site, and where the programs and files are.
$TestDomain = 'youtube.com'
$TestPageUrl = 'https://www.youtube.com'
$CliExe = Join-Path $env:ProgramFiles 'SiteBlock\siteblock.exe'
$HostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$ServiceNames = @('SiteBlock', 'SiteBlockWatchdog')
$SkipAdvice = 'Block youtube.com from the shield icon by the clock, then run verify-install.ps1 again.'

$script:PassCount = 0
$script:FailCount = 0
$script:SkipCount = 0
$script:StatusText = ''
$script:StatusCode = 1

# Records and prints a passed check.
function Write-Pass([string]$text) {
    $script:PassCount++
    Write-Host "PASS: $text" -ForegroundColor Green
}

# Records and prints a failed check.
function Write-Fail([string]$text) {
    $script:FailCount++
    Write-Host "FAIL: $text" -ForegroundColor Red
}

# Records and prints a check that was skipped because it does not apply yet.
function Write-Skip([string]$text) {
    $script:SkipCount++
    Write-Host "SKIP: $text" -ForegroundColor Yellow
}

# Prints a heading for a check.
function Write-Heading([int]$number, [string]$text) {
    Write-Host ''
    Write-Host "[$number] $text"
}

# Prints text indented, for command output shown under a check.
function Write-Indented([string]$text) {
    foreach ($line in ($text -split "`r?`n")) { Write-Host "    $line" }
}

# Runs a program and returns its exit code and everything it printed. Output is collected through .NET rather than
# PowerShell's 2>&1, because in Windows PowerShell 5.1 that turns any error text into a script-stopping error.
function Invoke-Native([string]$filePath, [string]$arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $filePath
    $info.Arguments = $arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    # Standard input is closed at once, so a command that unexpectedly asks for a password ends instead of waiting.
    $process.StandardInput.Close()
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        try { $process.Kill() } catch { }
        return New-Object PSObject -Property @{ ExitCode = -1; Output = 'timed out after 30 seconds' }
    }
    return New-Object PSObject -Property @{ ExitCode = $process.ExitCode; Output = ($outTask.Result + $errTask.Result).TrimEnd() }
}

# Check 1: both services are installed and running.
function Test-Services {
    Write-Heading 1 'the SiteBlock services are running'
    foreach ($name in $ServiceNames) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-Fail "the $name service is not installed (run Install SiteBlock.cmd again)"
        } elseif ($service.Status -ne 'Running') {
            Write-Fail "the $name service is $($service.Status), not Running (run Install SiteBlock.cmd again)"
        } else {
            Write-Pass "the $name service is running"
        }
    }
}

# Check 2: the command-line tool can talk to the service. The text and exit code are kept for the checks that follow.
function Test-Status {
    Write-Heading 2 'siteblock status works'
    if (-not (Test-Path -LiteralPath $CliExe -PathType Leaf)) {
        $script:StatusCode = 1
        Write-Fail "$CliExe is missing (run Install SiteBlock.cmd again)"
        return
    }
    $result = Invoke-Native $CliExe 'status'
    $script:StatusText = $result.Output
    $script:StatusCode = $result.ExitCode
    Write-Indented $result.Output
    if ($result.ExitCode -eq 0) {
        Write-Pass 'siteblock status exited 0'
    } else {
        Write-Fail "siteblock status exited $($result.ExitCode) (2 means the SiteBlock service is not answering)"
    }
}

# True when the saved status text lists the test site. Each site line looks like "  youtube.com (28 hosts)".
function Test-SiteIsBlocked {
    if ($script:StatusCode -ne 0) { return $false }
    foreach ($line in ($script:StatusText -split "`r?`n")) {
        if ($line.StartsWith("  $TestDomain (")) { return $true }
    }
    return $false
}

# Prints the SKIP line for a blocking check when the test site is not blocked, or when its state is unknown.
function Write-SkipUntilBlocked {
    if ($script:StatusCode -ne 0) {
        Write-Skip "cannot tell whether $TestDomain is blocked, because siteblock status failed (see check 2)"
    } else {
        Write-Skip $SkipAdvice
    }
}

# Returns the hosts file's lines with spaces trimmed, or an empty list when it cannot be read.
function Get-HostsLines {
    try {
        return @([System.IO.File]::ReadAllLines($HostsFile) | ForEach-Object { $_.Trim() })
    } catch {
        return @()
    }
}

# Check 3: the hosts file has the lines that block the test site.
function Test-HostsLines {
    Write-Heading 3 "the hosts file has the lines that block $TestDomain"
    if (-not (Test-SiteIsBlocked)) { Write-SkipUntilBlocked; return }
    $lines = @(Get-HostsLines)
    $missing = 0
    foreach ($wanted in @("0.0.0.0 $TestDomain", "0.0.0.0 www.$TestDomain", "0.0.0.0 m.$TestDomain", '0.0.0.0 youtu.be', ":: $TestDomain")) {
        if ($lines -contains $wanted) {
            Write-Host "    found: $wanted"
        } else {
            Write-Host "    MISSING: $wanted"
            $missing++
        }
    }
    if ($missing -eq 0) {
        Write-Pass "$HostsFile contains every expected line for $TestDomain"
    } else {
        Write-Fail "$HostsFile is missing $missing expected lines for $TestDomain"
    }
}

# Check 4: the Windows name lookup (not just the file) returns 0.0.0.0 for the test site.
function Test-Lookup {
    Write-Heading 4 "the Windows name lookup returns 0.0.0.0 for www.$TestDomain"
    if (-not (Test-SiteIsBlocked)) { Write-SkipUntilBlocked; return }
    $text = ''
    # The service empties the name cache after each change, but a retry or two costs nothing and avoids a false alarm.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $addresses = @([System.Net.Dns]::GetHostAddresses("www.$TestDomain") | ForEach-Object { $_.ToString() })
            $text = $addresses -join ', '
            $real = @($addresses | Where-Object { $_ -ne '0.0.0.0' -and $_ -ne '::' })
            if ($addresses.Count -gt 0 -and $real.Count -eq 0) {
                Write-Pass "www.$TestDomain resolves to $text"
                return
            }
        } catch {
            $text = "lookup failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 1
    }
    Write-Fail "www.$TestDomain did not resolve to 0.0.0.0 (got: $text)"
}

# Check 5: a real connection attempt to the test page fails.
function Test-WebConnection {
    Write-Heading 5 "a real connection to $TestPageUrl fails"
    if (-not (Test-SiteIsBlocked)) { Write-SkipUntilBlocked; return }
    try {
        Invoke-WebRequest -Uri $TestPageUrl -UseBasicParsing -TimeoutSec 5 | Out-Null
        Write-Fail "$TestPageUrl loaded, so the site is NOT blocked"
    } catch {
        Write-Pass "$TestPageUrl could not be reached ($($_.Exception.Message))"
    }
}

# Returns the string values of a registry list key (such as Chrome's URLBlocklist), or an empty list when it is missing.
function Get-PolicyList([string]$path) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $base.OpenSubKey($path)
    if ($null -eq $key) { return @() }
    try {
        return @($key.GetValueNames() | ForEach-Object { [string]$key.GetValue($_) })
    } finally {
        $key.Close()
    }
}

# Check 6: each browser's policy in the registry blocks the test site.
function Test-BrowserPolicies {
    Write-Heading 6 "the browsers' policy settings block $TestDomain"
    if (-not (Test-SiteIsBlocked)) { Write-SkipUntilBlocked; return }
    $targets = @(
        @{ Browser = 'Chrome'; Path = 'SOFTWARE\Policies\Google\Chrome\URLBlocklist'; Entry = $TestDomain },
        @{ Browser = 'Edge'; Path = 'SOFTWARE\Policies\Microsoft\Edge\URLBlocklist'; Entry = $TestDomain },
        @{ Browser = 'Brave'; Path = 'SOFTWARE\Policies\BraveSoftware\Brave\URLBlocklist'; Entry = $TestDomain },
        @{ Browser = 'Firefox'; Path = 'SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block'; Entry = "*://*.$TestDomain/*" }
    )
    foreach ($target in $targets) {
        $values = @(Get-PolicyList $target.Path)
        if ($values -contains $target.Entry) {
            Write-Pass "$($target.Browser): HKLM\$($target.Path) holds $($target.Entry)"
        } else {
            Write-Fail "$($target.Browser): HKLM\$($target.Path) does not hold $($target.Entry)"
        }
    }
}

# Check 7: the service reports a healthy hosts file, and SiteBlock's section is in it. The section is always there
# while SiteBlock is installed, because the adult content filter is always on and keeps a few names blocked.
function Test-HostsHealthy {
    Write-Heading 7 'the SiteBlock service reports a healthy hosts file'
    if ($script:StatusCode -ne 0) {
        Write-Skip 'cannot check the hosts file, because siteblock status failed (see check 2)'
        return
    }
    if ($script:StatusText -match 'hosts file could not be brought into the right state') {
        Write-Fail 'siteblock status warns that the hosts file is not in the right state'
    } else {
        Write-Pass 'siteblock status shows no hosts file warning'
    }
    $lines = @(Get-HostsLines)
    $hasBegin = @($lines | Where-Object { $_.StartsWith('# BEGIN SiteBlock') }).Count -gt 0
    $hasEnd = @($lines | Where-Object { $_.StartsWith('# END SiteBlock') }).Count -gt 0
    if ($hasBegin -and $hasEnd) {
        Write-Pass "$HostsFile has SiteBlock's BEGIN and END markers"
    } else {
        Write-Fail "$HostsFile is missing SiteBlock's BEGIN and END markers"
    }
}

# Prints the result totals and what to do next. Skipped checks do not count as failures.
function Write-Summary {
    Write-Host ''
    Write-Host '=============================================='
    Write-Host "Summary: $($script:PassCount) passed, $($script:FailCount) failed, $($script:SkipCount) skipped"
    if ($script:FailCount -eq 0) {
        Write-Host 'RESULT: PASS (no failed checks)' -ForegroundColor Green
    } else {
        Write-Host "RESULT: FAIL ($($script:FailCount) failed checks)" -ForegroundColor Red
    }
    if (Test-SiteIsBlocked) {
        Write-Host ''
        Write-Host "$TestDomain stays blocked. To unblock it later (needs your SiteBlock password and a wait):"
        Write-Host "    siteblock unblock $TestDomain"
    } elseif ($script:StatusCode -eq 0) {
        Write-Host ''
        Write-Host "The blocking checks were skipped because $TestDomain is not blocked yet."
        Write-Host $SkipAdvice
    }
}

Test-Services
Test-Status
Test-HostsLines
Test-Lookup
Test-WebConnection
Test-BrowserPolicies
Test-HostsHealthy
Write-Summary
if ($script:FailCount -gt 0) { exit 1 }
exit 0
