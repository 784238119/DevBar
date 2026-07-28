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
checksum_path="${archive_path}.sha256"

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

rm -f "${archive_path}" "${checksum_path}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app_path}" "${archive_path}"

(
  cd "${dist_dir}"
  /usr/bin/shasum -a 256 "${archive_path:t}" > "${checksum_path:t}"
)

print "Created ${archive_path}"
print "Created ${checksum_path}"
