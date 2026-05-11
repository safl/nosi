#!/usr/bin/env bash
# Render the cloud-init NoCloud seed for one image. Supports multiple SSH
# public keys (one per line in the source file) — they render as a YAML list.
#
# Usage: render-seed.sh <image>
#   <image>   sub-image name under mkosi.images/ (e.g. debian-base)
#
# SSH key source (first hit wins):
#   $CSI_SSH_PUBKEY   path to a file containing one or more public keys
#   ~/.ssh/id_ed25519.pub
#
# In CI the workflow populates $CSI_SSH_PUBKEY with the keys fetched from
# https://github.com/<owner>.keys; locally, your default key is used.
#
# The rendered seed lives under mkosi.images/<image>/mkosi.extra/ and is
# gitignored — never edit it directly.

set -euo pipefail

image=${1:?usage: render-seed.sh <image>}

case $image in
        debian-base) hostname=csi-debian ;;
        ubuntu-base) hostname=csi-ubuntu ;;
        fedora-base) hostname=csi-fedora ;;
        *) echo "render-seed.sh: unknown image '$image'" >&2; exit 1 ;;
esac

pubkey_file=${CSI_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}
if [[ ! -r $pubkey_file ]]; then
        cat >&2 <<EOF
render-seed.sh: SSH public key file not readable at $pubkey_file
                set CSI_SSH_PUBKEY=/path/to/key(s).pub to override.
EOF
        exit 1
fi

key_count=$(awk 'NF' "$pubkey_file" | wc -l)
if (( key_count == 0 )); then
        echo "render-seed.sh: no usable keys in $pubkey_file" >&2
        exit 1
fi

seed_dir="mkosi.images/$image/mkosi.extra/var/lib/cloud/seed/nocloud"
mkdir -p "$seed_dir"

{
        cat <<EOF
#cloud-config
# Rendered by scripts/render-seed.sh. Edit the script, not this file.

hostname: $hostname
preserve_hostname: false

users:
  - name: odus
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
EOF
        awk 'NF { printf "      - %s\n", $0 }' "$pubkey_file"
        cat <<'EOF'

system_info:
  default_user:
    name: odus

ssh_pwauth: false
disable_root: true
EOF
} > "$seed_dir/user-data"

cat > "$seed_dir/meta-data" <<EOF
instance-id: $hostname
local-hostname: $hostname
EOF

echo "rendered $image seed: hostname=$hostname keys=$key_count source=$pubkey_file"
