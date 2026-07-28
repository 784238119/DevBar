#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
master="${project_dir}/Resources/AppIcon-master.png"
icon_dir="${project_dir}/Resources/Assets.xcassets/AppIcon.appiconset"

test -f "${master}"
mkdir -p "${icon_dir}"

while IFS=: read -r pixels filename; do
  /usr/bin/sips -z "${pixels}" "${pixels}" "${master}" \
    --out "${icon_dir}/${filename}" >/dev/null
done <<'SIZES'
16:icon_16x16.png
32:icon_16x16@2x.png
32:icon_32x32.png
64:icon_32x32@2x.png
128:icon_128x128.png
256:icon_128x128@2x.png
256:icon_256x256.png
512:icon_256x256@2x.png
512:icon_512x512.png
1024:icon_512x512@2x.png
SIZES
