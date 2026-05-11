#!/usr/bin/env bash
# Package a mkosi-built raw image for bty:
#   - locate the raw output by ImageId
#   - compress to .raw.zst
#   - emit a .sha256 sidecar of the *compressed* artifact
#
# Usage: package.sh <image> <dist-dir>
#   <image>    sub-image directory name under mkosi.images/ (e.g. debian-base)
#   <dist-dir> output directory for packaged artifacts

set -euo pipefail

image=${1:?usage: package.sh <image> <dist-dir>}
dist=${2:?usage: package.sh <image> <dist-dir>}

id="csi-${image}"
src="mkosi.output/${id}.raw"

if [[ ! -f $src ]]; then
        echo "package.sh: $src not found; run 'make $image' first" >&2
        exit 1
fi

mkdir -p "$dist"
out="$dist/${id}.raw.zst"

zstd -19 -T0 -f "$src" -o "$out"
( cd "$dist" && sha256sum "${id}.raw.zst" > "${id}.raw.zst.sha256" )

echo "packaged: $out"
cat "$dist/${id}.raw.zst.sha256"
