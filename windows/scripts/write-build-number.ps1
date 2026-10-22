# Writes windows/BuildNumber.props with the number of commits on the checked-out branch, or 0 when git is not available.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
$count = 0
try {
    $out = & git -C $here rev-list --count HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $out -match '^\d+$') { $count = [int]$out }
} catch { $count = 0 }
# On GitHub the count must be real: a build numbered 0 would be published as an older version than every install.
if ($count -eq 0 -and $env:GITHUB_ACTIONS -eq 'true') { throw 'The build number could not be read from git (the commit count was 0 or git failed).' }
$props = "<Project>`n  <PropertyGroup>`n    <SiteBlockBuildNumber>$count</SiteBlockBuildNumber>`n  </PropertyGroup>`n</Project>`n"
[System.IO.File]::WriteAllText((Join-Path $here 'BuildNumber.props'), $props)
Write-Output "build number: $count"
