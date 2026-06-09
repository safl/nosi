#!/usr/bin/env bash
# nosi/provision/steps/96-disk-report.sh
#
# Read-only: log the rootfs disk consumption near the end of provisioning, so
# the bake log shows exactly what fills the image (and what a cleanup could
# target) without anyone having to mount the artifact. Purely diagnostic --
# this step changes nothing on disk.
#
# Output lands in the bake log: cloud-init-output.log (uploaded as a build
# artifact on x86) and the live build-rpi step log (Pi chroot). It runs late
# (96) so almost everything is installed; the final cache trim happens after
# apply.sh, so the totals here are a slight over-count of what actually ships
# -- the directory breakdown is the point, not the last few hundred MiB.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 96-disk-report (distro=$NOSI_DISTRO)"

if nosi_is_wsl; then
    nosi_info "WSL detected; the host owns the disk, skipping"
    exit 0
fi

nosi_info "rootfs usage (df -h /):"
df -h / 2>/dev/null || true

nosi_info "largest directories (du -hxd2 /, top 30):"
# -x stays on the rootfs so the bind-mounted /proc /sys /dev (different
# filesystems) are skipped in the Pi chroot; depth 2 is enough to spot the
# big consumers (firmware, toolchains, /usr/lib, /usr/src on FreeBSD).
du -hxd2 / 2>/dev/null | sort -rh | head -n 30 || true

nosi_info "step 96-disk-report done"
