#!/usr/bin/env bash
# nosi/provision/steps/27-snapd-disable.sh
#
# Soft-disable snapd on Ubuntu. Ubuntu cloud images ship it preinstalled;
# headless / aidev do not use snaps (apt + podman cover the same ground) and
# snapd's running daemon + auto-refresh + squashfs loop mounts add
# measurable runtime overhead on a flashed bare-metal box (a process in
# `ps aux` / htop, resident memory, periodic CPU wakeups, /snap loop
# devices cluttering `df` / `mount`).
#
# We do NOT purge snapd. Keeping the package installed but masked means an
# operator who later wants a snap can re-enable in three commands without
# a reinstall:
#
#     sudo systemctl unmask snapd.socket snapd.service
#     sudo systemctl enable --now snapd.socket
#     sudo snap install <whatever>     # re-seeds core on first install
#
# What this step does:
#   1. Remove any seeded snaps (while snapd is still running) so their
#      squashfs loops unmount and the disk space comes back.
#   2. Stop + mask the snapd units so nothing runs at boot.
# The snapd package, its apt source, and /var/lib/snapd stay in place so
# the re-enable above is clean.
#
# No-op on Debian (snapd not installed) and Fedora (no snapd). Gated on
# the snapd package so a re-run after disabling is also a no-op.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 27-snapd-disable"

if [ "$NOSI_DISTRO" != "ubuntu" ]; then
    nosi_info "non-ubuntu distro ($NOSI_DISTRO); skipping"
    exit 0
fi

if ! nosi_pkg_installed snapd; then
    nosi_info "snapd not installed; nothing to disable"
    exit 0
fi

nosi_require_root

# 1. Drain seeded snaps so squashfs loops unmount and disk frees up.
#    Needs snapd running, so do this before masking. Iterate: some snaps
#    refuse removal until their dependents go (core / snapd base is last).
if command -v snap >/dev/null 2>&1; then
    for _ in 1 2 3; do
        snaps=$(snap list 2>/dev/null | awk 'NR>1 {print $1}') || true
        [ -z "$snaps" ] && break
        for s in $snaps; do
            snap remove --purge "$s" 2>/dev/null || true
        done
    done
fi

# 2. Stop + mask every snapd unit so nothing starts at boot. Masking the
#    socket is what actually keeps it down (snapd is socket-activated);
#    the rest are masked for completeness so no snapd unit lingers active.
#    `systemctl mask` is idempotent; |true catches units that do not
#    exist on a given snapd version.
snapd_units="snapd.socket snapd.service snapd.seeded.service
             snapd.apparmor.service snapd.autoimport.service
             snapd.recovery-chooser-trigger.service
             snapd.snap-repair.timer snapd.snap-repair.service"

# shellcheck disable=SC2086
systemctl stop $snapd_units 2>/dev/null || true
# shellcheck disable=SC2086
systemctl mask $snapd_units 2>/dev/null || true

# Keep the package across the `apt-get autoremove --purge` passes in
# step 26 and the cloud-init cleanup: mark it manually-installed so it is
# never treated as an orphan. This is what makes "masked, not purged"
# actually stick.
apt-mark manual snapd 2>/dev/null || true

nosi_info "step 27-snapd-disable done (snapd masked, package retained)"
