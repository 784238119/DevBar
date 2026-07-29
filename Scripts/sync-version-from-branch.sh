#!/bin/zsh
set -euo pipefail

branch="${1:-}"
plist="${2:-${0:A:h:h}/Configuration/DevBar-Info.plist}"
version="${branch#dev-}"

if [[ "$branch" != "dev-$version" || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  print -u2 "Expected a branch named dev-X.Y.Z, got: $branch"
  exit 1
fi

current_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
current_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")

if ! [[ "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  print -u2 "CFBundleShortVersionString must use X.Y.Z, got: $current_version"
  exit 1
fi

if [[ "$current_version" == "$version" ]]; then
  print "Version is already $version."
  exit 0
fi

if ! [[ "$current_build" =~ ^[0-9]+$ ]]; then
  print -u2 "CFBundleVersion must be numeric, got: $current_build"
  exit 1
fi

if ! /usr/bin/awk -v current="$current_version" -v target="$version" '
  BEGIN {
    split(current, currentParts, ".")
    split(target, targetParts, ".")
    for (i = 1; i <= 3; i++) {
      if ((targetParts[i] + 0) > (currentParts[i] + 0)) exit 0
      if ((targetParts[i] + 0) < (currentParts[i] + 0)) exit 1
    }
    exit 1
  }
'; then
  print -u2 "Target version $version must be newer than $current_version."
  exit 1
fi

next_build=$((current_build + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" "$plist"

print "Updated version $current_version ($current_build) -> $version ($next_build)."
