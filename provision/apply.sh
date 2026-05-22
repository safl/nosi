#!/usr/bin/env bash
# nosi/provision/apply.sh <flavor>
#
# Run every provision step for <flavor> in order. Flavors:
#
#   debian-sysdev   sysdev on Debian (apt)
#   ubuntu-sysdev   sysdev on Ubuntu (apt)
#   ubuntu-aidev    aidev on Ubuntu (apt; superset of ubuntu-sysdev + AI CLIs)
#   fedora-sysdev   sysdev on Fedora (dnf)
#
# Each step is independently idempotent, so apply.sh is also idempotent:
# re-running on the same system does nothing the second time. Steps that
# touch kernel cmdline / initramfs may require a reboot to take effect.
#
# This script is invoked from cloud-init at bake time and from the
# operator's shell on a vanilla Hetzner VM (or similar). Same code path
# in both cases.

set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

FLAVOR="${1:-}"
[ -n "$FLAVOR" ] || nosi_die "usage: $0 <flavor>   (debian-sysdev | ubuntu-sysdev | ubuntu-aidev | fedora-sysdev)"

case "$FLAVOR" in
debian-sysdev|ubuntu-sysdev|fedora-sysdev)
    export NOSI_FLAVOR=sysdev
    ;;
ubuntu-aidev)
    export NOSI_FLAVOR=aidev
    ;;
*)
    nosi_die "unknown flavor: $FLAVOR"
    ;;
esac

# Steps the flavor wants, in order. As more steps are extracted from
# the inline cloud-init blocks they get appended here. Each entry is a
# basename under provision/steps/ minus the .sh extension.
STEPS=(
    10-r8125-dkms
    20-upstream-tools
    21-shell-tools
    22-python-tools
    23-userspace-pci
    24-podman-setup
    25-iommu-cmdline
    26-daemon-prune
    27-snapd-disable
    28-ssh-config
    29-rotate-password
    30-clock-from-http
    31-motd
    32-firstboot-inventory
    40-nerd-font
    41-npm-globals
    42-pi-cli
    43-wsl-config
)

nosi_info "apply start: flavor=$FLAVOR distro=$NOSI_DISTRO pkgmgr=$NOSI_PKGMGR"

for s in "${STEPS[@]}"; do
    script="$HERE/steps/${s}.sh"
    [ -x "$script" ] || nosi_die "missing step: $script"
    nosi_info "--- step $s ---"
    "$script"
done

nosi_info "apply complete: $FLAVOR"
