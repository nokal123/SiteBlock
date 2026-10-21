#!/bin/bash
# Writes windows/BuildNumber.props with the number of commits on the checked-out branch, or 0 when git is not available.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
count=0
if command -v git >/dev/null 2>&1 && git -C "$here" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  count="$(git -C "$here" rev-list --count HEAD 2>/dev/null || echo 0)"
fi
[[ "$count" =~ ^[0-9]+$ ]] || count=0
cat > "$here/BuildNumber.props" <<PROPS
<Project>
  <PropertyGroup>
    <SiteBlockBuildNumber>$count</SiteBlockBuildNumber>
  </PropertyGroup>
</Project>
PROPS
echo "build number: $count"
