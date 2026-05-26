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

set -uo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

# common.sh sets `set -e` so individual steps abort on first error. apply.sh
# needs the OPPOSITE: a single step's failure must not skip every step that
# follows, otherwise one transient pip / curl hiccup quietly leaves the
# image missing sshd-enable, the motd renderer, the firstboot inventory,
# etc. (and the bake still "succeeds" because cloud-init just moves to
# the next runcmd entry). Clear -e here, collect failures per step, exit
# non-zero with a list at the end.
set +e

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

# Full flavor string (e.g. "ubuntu-sysdev") for identity-aware steps.
export NOSI_VARIANT="$FLAVOR"

# Steps the flavor wants, in order. As more steps are extracted from
# the inline cloud-init blocks they get appended here. Each entry is a
# basename under provision/steps/ minus the .sh extension.
STEPS=(
    # 05-nosi-release runs FIRST so /etc/nosi-release captures the build
    # identity even if a later step explodes -- forensics need the version
    # tag before anything else can break.
    05-nosi-release
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
    32-firstboot-inventory
    40-nerd-font
    41-npm-globals
    42-pi-cli
    43-wsl-config
    # 99-motd runs LAST so the login banner's presence is the at-a-glance
    # signal that the whole apply chain succeeded: see the nosi banner ->
    # everything before it ran; no banner -> something broke before the end,
    # and /etc/nosi-release (written first) tells you exactly which build.
    99-motd
)

nosi_info "apply start: flavor=$FLAVOR variant=$NOSI_VARIANT distro=$NOSI_DISTRO pkgmgr=$NOSI_PKGMGR"

failed=()
for s in "${STEPS[@]}"; do
    script="$HERE/steps/${s}.sh"
    [ -x "$script" ] || nosi_die "missing step: $script"
    nosi_info "--- step $s ---"
    "$script"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        nosi_warn "step $s exited with code $rc; continuing"
        failed+=("$s")
    fi
done

if [ "${#failed[@]}" -ne 0 ]; then
    nosi_warn "apply finished with failed steps: ${failed[*]}"
    exit 1
fi
nosi_info "apply complete: $FLAVOR"
