#!/bin/zsh
set -euo pipefail

# Required GitHub Actions secret: SPARKLE_PRIVATE_KEY.
root="${0:A:h:h}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Configuration/DevBar-Info.plist")
derived="$root/.build/ReleaseDerivedData"
dist="$root/dist"
app="$derived/Build/Products/Release/DevBar.app"
dmg="$dist/DevBar-${version}-macos-arm64.dmg"
stage=$(mktemp -d "${TMPDIR:-/tmp}/DevBar-DMG.XXXXXX")
appcast_stage=$(mktemp -d "${TMPDIR:-/tmp}/DevBar-Appcast.XXXXXX")
trap 'rm -rf "$stage" "$appcast_stage"' EXIT

for name in SPARKLE_PRIVATE_KEY; do
  [[ -n "${(P)name:-}" ]] || { print -u2 "Missing $name"; exit 1; }
done

rm -rf "$derived" "$dist"
mkdir -p "$dist"
xcodebuild -project "$root/DevBar.xcodeproj" -scheme DevBar -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
codesign --verify --deep --strict --verbose=2 "$app"
ditto "$app" "$stage/DevBar.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "DevBar $version" -srcfolder "$stage" -format UDZO -ov "$dmg"

tool="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$tool" ]] || { print -u2 'Sparkle generate_appcast not found'; exit 1; }
ditto "$dmg" "$appcast_stage/${dmg:t}"
[[ -f "$root/appcast.xml" ]] && ditto "$root/appcast.xml" "$appcast_stage/appcast.xml"
print -rn -- "$SPARKLE_PRIVATE_KEY" | "$tool" --ed-key-file - --account DevBar --maximum-deltas 0 \
  --download-url-prefix "https://github.com/784238119/DevBar/releases/download/v${version}/" \
  --link "https://github.com/784238119/DevBar/releases/tag/v${version}" "$appcast_stage"
ditto "$appcast_stage/appcast.xml" "$root/appcast.xml"
shasum -a 256 "$dmg" > "$dmg.sha256"
