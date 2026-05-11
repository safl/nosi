#!/usr/bin/env bash
# Convert a cijoe-built qcow2 to .raw.zst + sha256 in $DIST.
#
# Usage: package.sh <variant> <dist-dir>
#   <variant>  name without the csi- prefix (e.g. debian-base)
#   <dist-dir> output directory for packaged artefacts

set -euo pipefail

variant=${1:?usage: package.sh <variant> <dist-dir>}
dist=${2:?usage: package.sh <variant> <dist-dir>}

src="$HOME/system_imaging/disk/csi-${variant}-x86_64.qcow2"
if [[ ! -f $src ]]; then
        echo "package.sh: $src not found; run 'make build VARIANT=$variant' first" >&2
        exit 1
fi

mkdir -p "$dist"
raw="$dist/csi-${variant}.raw"
out="$dist/csi-${variant}.raw.zst"

qemu-img convert -f qcow2 -O raw "$src" "$raw"
zstd -19 -T0 -f "$raw" -o "$out"
rm -f "$raw"
( cd "$dist" && sha256sum "csi-${variant}.raw.zst" > "csi-${variant}.raw.zst.sha256" )

echo "packaged: $out"
cat "$dist/csi-${variant}.raw.zst.sha256"
