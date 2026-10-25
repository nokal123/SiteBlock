# Decides whether a freshly built package is a new release, by comparing the build number in its version-windows.json with the one
# already published. Prints "release" when the new build is higher, so the workflow publishes it, and "skip" when it is the same,
# because the release number in windows/version.props was not raised and this push is not meant as a release.
# A lower new build, or a file without a whole-number build, is an error (exit 1): installed copies would never take a lower
# build, so publishing it would strand them.
#
#   pwsh windows/scripts/release-check.ps1 <new version-windows.json> <published version-windows.json>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$NewFile,
    [Parameter(Mandatory = $true, Position = 1)][string]$PublishedFile
)
$ErrorActionPreference = 'Stop'

# The "build" field of a version file as a number, or an error naming the file when it is missing or not a whole number.
function Get-Build([string]$path) {
    $build = $null
    try { $build = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).build } catch { $build = $null }
    # Only a JSON whole number counts: ConvertFrom-Json gives an integer type for one, and a string such as "95" or a decimal such as 95.5 is refused.
    if ($build -isnot [int] -and $build -isnot [long]) {
        [Console]::Error.WriteLine("error: $path has no whole-number build field")
        exit 1
    }
    return [long]$build
}

$new = Get-Build $NewFile
$published = Get-Build $PublishedFile
if ($new -gt $published) {
    Write-Output 'release'
} elseif ($new -eq $published) {
    Write-Output 'skip'
} else {
    [Console]::Error.WriteLine("error: the new build $new is lower than the published build $published; installed copies would never take it")
    exit 1
}
