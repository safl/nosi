#!/usr/bin/env bash
# nosi/provision/apply.sh <variant>
#
# Run every provision step for <variant> in order. The variant is
# `<distro>-<version>-<shape>`, e.g.:
#
#   debian-13-headless    headless on Debian 13 (apt)
#   ubuntu-2604-headless  headless on Ubuntu 26.04 (apt)
#   fedora-44-headless    headless on Fedora 44 (dnf)
#   fedora-44-desktop     desktop on Fedora 44 (dnf; Sway tiling stack)
#
# Shape is parsed from the suffix (-headless / -desktop); the rest is
# informational (lib/common.sh detects the live distro/pkgmgr from
# /etc/os-release, so version-in-name doesn't gate any step). Optional
# post-flash tooling (agentic CLIs, GPU vendor stacks, ...) lives in
# /opt/nosi/addons/ and is operator-launched via nosi-addon -- not part
# of the baked apply chain.
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

# Fail-fast on first step error: a step abort means /etc/nosi/apply-ok
# is never written, the smoketest's sentinel-presence assertion fails,
# and the image is refused for publish regardless of which step died.
# Without strict mode, a tool-install failure could leave a qcow2 that
# looks valid (/etc/nosi-release written, motd rendered, sshd enabled)
# but is silently missing whichever tools the failed step was supposed
# to install -- a smoketest only catches what it asserts.

VARIANT="${1:-}"
[ -n "$VARIANT" ] || nosi_die "usage: $0 <variant>   (e.g. debian-13-headless | ubuntu-2604-wsl | fedora-44-desktop)"

# Shape is the trailing -headless / -desktop / -wsl segment. Distro +
# version are carried in the variant name but not enforced here:
# lib/common.sh derives the live NOSI_DISTRO / NOSI_PKGMGR from
# /etc/os-release, so an operator-side `apply.sh ubuntu-2604-headless` on
# a different-version Ubuntu box still works -- the variant string is
# identity / catalog metadata, not a runtime selector.
case "$VARIANT" in
*-headless) export NOSI_SHAPE=headless ;;
*-desktop)  export NOSI_SHAPE=desktop  ;;
*-wsl)      export NOSI_SHAPE=wsl      ;;
*)          nosi_die "variant must end in -headless, -desktop, or -wsl: $VARIANT" ;;
esac

# Full variant string (e.g. "ubuntu-2604-headless") for identity-aware steps.
export NOSI_VARIANT="$VARIANT"

# Steps the shape wants, in order. As more steps are extracted from
# the inline cloud-init blocks they get appended here. Each entry is a
# basename under provision/steps/ minus the .sh extension.
STEPS=(
    # 05-nosi-release runs FIRST so /etc/nosi-release captures the build
    # identity even if a later step explodes -- forensics need the version
    # tag before anything else can break.
    05-nosi-release
    10-r8125-dkms
    12-gdb-dashboard
    15-nouveau-blacklist
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
    45-nosi-addons
    50-desktop-stack
    # 98-metadata captures the actual installed inventory (kernel, tool
    # versions, manually-installed packages) into /etc/nosi-metadata.json
    # AFTER every tool-install step has finished. Smoketest scp's it out so
    # it ships as an ORAS layer next to the .img.gz.
    98-metadata
    # 99-motd runs LAST so the login banner's presence is the at-a-glance
    # signal that the whole apply chain succeeded: see the nosi banner ->
    # everything before it ran; no banner -> something broke before the end,
    # and /etc/nosi-release (written first) tells you exactly which build.
    99-motd
)

nosi_info "apply start: variant=$NOSI_VARIANT shape=$NOSI_SHAPE distro=$NOSI_DISTRO pkgmgr=$NOSI_PKGMGR"

for s in "${STEPS[@]}"; do
    script="$HERE/steps/${s}.sh"
    [ -x "$script" ] || nosi_die "missing step: $script"
    nosi_info "--- step $s ---"
    "$script"
done

# All steps completed. Write the success sentinel. The smoketest's only
# whole-chain assertion checks for this file; absence => apply.sh aborted
# somewhere => image is refused for publish. The timestamp inside the
# file is useful for forensics (Hetzner-VM re-runs overwrite it).
install -d -m 0755 /etc/nosi
date -u +%Y-%m-%dT%H:%M:%SZ > /etc/nosi/apply-ok
nosi_info "apply complete: $VARIANT (sentinel: /etc/nosi/apply-ok)"
