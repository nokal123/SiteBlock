# Writes windows/BuildNumber.props with the number of commits on the checked-out branch, or 0 when git is not available.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
$count = 0
try {
    $out = & git -C $here rev-list --count HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $out -match '^\d+$') { $count = [int]$out }
} catch { $count = 0 }
$props = "<Project>`n  <PropertyGroup>`n    <SiteBlockBuildNumber>$count</SiteBlockBuildNumber>`n  </PropertyGroup>`n</Project>`n"
[System.IO.File]::WriteAllText((Join-Path $here 'BuildNumber.props'), $props)
Write-Output "build number: $count"
