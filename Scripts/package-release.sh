#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
info_plist="${project_root}/Configuration/DevBar-Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${info_plist}")
architecture="${DEVBAR_RELEASE_ARCH:-arm64}"
derived_data="${project_root}/.build/ReleaseDerivedData"
app_path="${derived_data}/Build/Products/Release/DevBar.app"
runner_path="${app_path}/Contents/Helpers/DevBarRunner"
dist_dir="${project_root}/dist"
archive_path="${dist_dir}/DevBar-${version}-macos-${architecture}.zip"
archive_checksum_path="${archive_path}.sha256"
dmg_path="${dist_dir}/DevBar-${version}-macos-${architecture}.dmg"
dmg_checksum_path="${dmg_path}.sha256"
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/DevBar-DMG.XXXXXX")
appcast_staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/DevBar-Appcast.XXXXXX")

cleanup() {
  rm -rf "${staging_dir}"
  rm -rf "${appcast_staging_dir}"
}
trap cleanup EXIT

mkdir -p "${dist_dir}"

xcodebuild \
  -project "${project_root}/DevBar.xcodeproj" \
  -scheme DevBar \
  -configuration Release \
  -destination "platform=macOS,arch=${architecture}" \
  -derivedDataPath "${derived_data}" \
  ARCHS="${architecture}" \
  ONLY_ACTIVE_ARCH=YES \
  build

[[ -d "${app_path}" ]] || {
  print -u2 "Release app was not produced at ${app_path}"
  exit 1
}

[[ -x "${runner_path}" ]] || {
  print -u2 "Embedded DevBarRunner is missing or not executable."
  exit 1
}

/usr/bin/codesign --verify --deep --strict --verbose=2 "${app_path}"

rm -f \
  "${archive_path}" \
  "${archive_checksum_path}" \
  "${dmg_path}" \
  "${dmg_checksum_path}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app_path}" "${archive_path}"

/usr/bin/ditto "${app_path}" "${staging_dir}/DevBar.app"
ln -s /Applications "${staging_dir}/Applications"
/usr/bin/hdiutil create \
  -volname "DevBar ${version}" \
  -srcfolder "${staging_dir}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "${dmg_path}"

(
  cd "${dist_dir}"
  /usr/bin/shasum -a 256 "${archive_path:t}" > "${archive_checksum_path:t}"
  /usr/bin/shasum -a 256 "${dmg_path:t}" > "${dmg_checksum_path:t}"
)

sparkle_generate_appcast="${derived_data}/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "${sparkle_generate_appcast}" ]] || {
  print -u2 "Sparkle generate_appcast was not found at ${sparkle_generate_appcast}"
  exit 1
}

/usr/bin/ditto "${dmg_path}" "${appcast_staging_dir}/${dmg_path:t}"
if [[ -f "${project_root}/appcast.xml" ]]; then
  /usr/bin/ditto "${project_root}/appcast.xml" "${appcast_staging_dir}/appcast.xml"
fi
"${sparkle_generate_appcast}" \
  --account DevBar \
  --maximum-deltas 0 \
  --download-url-prefix "https://github.com/784238119/DevBar/releases/download/v${version}/" \
  --link "https://github.com/784238119/DevBar/releases/tag/v${version}" \
  "${appcast_staging_dir}"
/usr/bin/ditto "${appcast_staging_dir}/appcast.xml" "${project_root}/appcast.xml"

print "Created ${archive_path}"
print "Created ${archive_checksum_path}"
print "Created ${dmg_path}"
print "Created ${dmg_checksum_path}"
print "Updated ${project_root}/appcast.xml"
