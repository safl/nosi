#!/bin/sh
# dracut mount hook for pixie ramboot (priority 90).
#
# Runs after ``pixie-ramboot-online.sh`` has attached /dev/nbd0 and
# after dracut's built-in mount hooks have (attempted to) mount
# /sysroot. Two modes gated on ``pixie.persist=1`` (or the legacy
# ``bty.persist=1``):
#
#   Ephemeral (default): mount the picked partition RO at
#   /run/pixie-lower, tmpfs at /run/pixie-upper, overlayfs at
#   /sysroot. Writes on the target go to RAM and vanish on reboot.
#
#   Persistent (``pixie.persist=1``): mount the picked partition RW
#   directly at /sysroot. Writes land on the underlying block device
#   (a qemu-nbd-served qcow2 in pixie's design) and survive reboots.
#   Skip the overlayfs and the fstab rewrite (the image's fstab is
#   still authoritative for /boot + /boot/efi, whose LABEL/UUID
#   entries resolve to real ``/dev/nbd0p*`` nodes under
#   ``nbd.max_part=16``).
#
# Both modes:
#
#   * Mask systemd-networkd + NetworkManager + cloud-init on the
#     pivoted rootfs so userspace does not tear down the NIC the
#     initrd owns.
#   * Propagate DNS from dracut's netroot config.
#   * POST a status ping so the pixie appliance can log ramboot.up.

# shellcheck disable=SC1091
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

_pixie_trace() { echo "pixie-ramboot: $*" >/dev/kmsg 2>/dev/null || echo "pixie-ramboot: $*"; }
_pixie_die() {
    _pixie_trace "FATAL: $*"
    _pixie_status "mount.died:$*"
    type emergency_shell >/dev/null 2>&1 && emergency_shell "pixie-ramboot: $*"
    exec sleep 2147483647
}

# Prefer ``pixie.*`` cmdline names; fall back to ``bty.*`` for legacy
# bundles booted against a bty appliance. Same payload; identical
# semantics.
_pixie_getarg() {
    key="$1"
    val="$(getarg "pixie.${key}=")"
    [ -n "$val" ] || val="$(getarg "bty.${key}=")"
    echo "$val"
}

# Best-effort HTTP status ping. Traces to /dev/kmsg vanish below the
# console loglevel on IPMI SoL, so this ships boot-phase progress to
# pixie's event log via ``POST /pxe/<mac>/status`` -- the same shape
# ``ramboot.up`` uses. Silent on failure.
_pixie_status() {
    _srv="$(_pixie_getarg server)"
    _mac="$(_pixie_getarg mac)"
    [ -n "$_srv" ] && [ -n "$_mac" ] || return 0
    wget -q -O /dev/null --timeout=3 --tries=1 \
        --post-data="status=$1" \
        "${_srv}/pxe/${_mac}/status" 2>/dev/null || true
}

nbd_url="$(_pixie_getarg nbd)"
[ -n "$nbd_url" ] || return 0
overlay_size="$(_pixie_getarg overlay_size)"
root_part_override="$(_pixie_getarg root_part)"
persist="$(_pixie_getarg persist)"
: "${overlay_size:=10G}"

_pixie_status "mount.started"

[ -b /dev/nbd0 ] || _pixie_die "mount hook: /dev/nbd0 missing (online hook didn't run?)"

# Ephemeral nbdboot: pixie's nbdkit serves the disk with
# ``--filter=partition partition=1`` already applied, so /dev/nbd0
# is the ext4 root filesystem and no override is needed. Persistent
# nbdboot: pixie's qemu-nbd serves the qcow2 wrapping the whole raw
# disk (partition table + all partitions), and the plan render
# passes ``pixie.root_part=/dev/nbd0p1`` so this hook mounts the
# Linux root partition instead of trying the whole disk as ext4.
if [ -n "$root_part_override" ]; then
    root_part="$root_part_override"
else
    root_part=/dev/nbd0
fi
_pixie_trace "mount hook: picked root_part=${root_part}"

# The online hook forces a partition rescan + waits for
# ``root_part_override`` before returning, but re-check here in
# case dracut fires this hook before /dev/nbd0pN is fully published
# (udev event race). One more partx+settle+poll cycle rather than
# a hard die.
if [ ! -b "$root_part" ]; then
    _pixie_trace "mount hook: ${root_part} not yet a block device; forcing partition scan"
    _pixie_status "mount.partscan_retry"
    partx -a /dev/nbd0 2>/dev/null || blockdev --rereadpt /dev/nbd0 2>/dev/null || true
    udevadm settle --timeout=10 || true
    i=0
    while [ "$i" -lt 100 ]; do
        [ -b "$root_part" ] && break
        sleep 0.1
        i=$((i + 1))
    done
fi
[ -b "$root_part" ] || _pixie_die "root_part ${root_part} is not a block device (partition scan produced no p<N> nodes)"
_pixie_status "mount.root_part_ready:${root_part}"

# dracut may have partially mounted /sysroot already from an earlier
# mount hook trying the baked root=UUID; unmount cleanly so our own
# mount lands on a clean directory. ``umount`` on a not-mounted path
# returns non-zero which we ignore; ``mountpoint`` isn't always in
# the initrd's busybox, so we can't gate on it.
umount /sysroot 2>/dev/null || true

if [ "$persist" = "1" ]; then
    # ---- persistent path ---------------------------------------------
    _pixie_trace "mount hook: persist=1; mount rw ${root_part} -> /sysroot"
    _pixie_status "mount.persist_start"
    mkdir -p /sysroot
    mnt_rc=1
    for fstype in ext4 xfs btrfs; do
        _pixie_trace "mount hook: mount -t ${fstype} -o rw ${root_part} -> /sysroot"
        if mount -t "$fstype" -o rw "$root_part" /sysroot 2>/dev/null; then
            mnt_rc=0
            _pixie_trace "mount hook: persist rw mount succeeded (${fstype})"
            break
        fi
    done
    [ "$mnt_rc" -eq 0 ] || _pixie_die "persist: failed to mount ${root_part} rw"
    upper=/sysroot
    _pixie_status "mount.persist_mounted"
else
    # ---- ephemeral path ----------------------------------------------
    _pixie_status "mount.ephemeral_start"
    mkdir -p /run/pixie-lower /run/pixie-upper
    mnt_rc=1
    for fstype in ext4 xfs btrfs auto; do
        _pixie_trace "mount hook: mount -t ${fstype} -o ro ${root_part} -> /run/pixie-lower"
        if mount -t "$fstype" -o ro "$root_part" /run/pixie-lower 2>/dev/null; then
            mnt_rc=0
            break
        fi
    done
    [ "$mnt_rc" -eq 0 ] || _pixie_die "failed to mount ${root_part}"

    _pixie_trace "mount hook: tmpfs(${overlay_size}) -> /run/pixie-upper"
    mount -t tmpfs -o "size=${overlay_size}" tmpfs /run/pixie-upper \
        || _pixie_die "failed to mount tmpfs"
    mkdir -p /run/pixie-upper/up /run/pixie-upper/work

    _pixie_trace "mount hook: overlay -> /sysroot"
    mkdir -p /sysroot
    mount -t overlay overlay \
        -o "lowerdir=/run/pixie-lower,upperdir=/run/pixie-upper/up,workdir=/run/pixie-upper/work" \
        /sysroot \
        || _pixie_die "failed to mount overlayfs at /sysroot"

    # Replace /etc/fstab in the overlay upper with a minimal one. The
    # image's fstab lists / (by LABEL cloudimg-rootfs), /boot, and
    # /boot/efi entries; letting systemd-fstab-generator materialise
    # any of them adds ordering deps on /dev/disk/by-uuid/* nodes
    # that never appear (we're not on a disk with a partition table
    # anymore). / is already mounted as the overlay from initrd, so
    # fstab has no more work to do.
    mkdir -p /run/pixie-upper/up/etc
    cat > /run/pixie-upper/up/etc/fstab <<EOF
# Written by nosi pixie-ramboot dracut hook -- ramboot overrides the
# image's baked /etc/fstab. / is already the initrd's overlay.
EOF
    _pixie_trace "mount hook: wrote minimal /etc/fstab in overlay upper"
    upper=/run/pixie-upper/up
    _pixie_status "mount.ephemeral_mounted"
fi

# Mask systemd-networkd + NetworkManager + cloud-init on the
# pivoted rootfs so they don't tear down the NIC dracut's network
# module set up (we still own it from the initrd side). Ubuntu
# 26.04 Server ships NetworkManager as the default network stack;
# without the NM masks below the pivoted userspace burns 60 s on
# NetworkManager-wait-online.service before its own online check
# times out. Observed live on GIGABYTE MC12-LE0 booting 2026.W29
# ubuntu-2604-headless: systemd-analyze critical-chain reported
# ``NetworkManager-wait-online.service @3.946s +59.988s`` alongside
# the identical +59 s burn on systemd-networkd-wait-online in the
# initrd (fixed separately by the wait-online mask in
# module-setup.sh). Symlinks land on the overlay upper (ephemeral)
# or directly on the RW rootfs (persist).
mkdir -p "${upper}/etc/systemd/system"
for unit in \
    systemd-networkd.service \
    systemd-networkd.socket \
    systemd-networkd-wait-online.service \
    NetworkManager.service \
    NetworkManager-wait-online.service \
    NetworkManager-dispatcher.service \
    nm-cloud-setup.service \
    nm-cloud-setup.timer \
    cloud-init.service \
    cloud-init-local.service \
    cloud-config.service \
    cloud-final.service \
; do
    ln -sf /dev/null "${upper}/etc/systemd/system/${unit}"
done
_pixie_trace "mount hook: masked networkd + NetworkManager + cloud-init on ${upper}"

# Propagate DNS from dracut's netroot config. dracut writes DNS to
# /tmp/net.*.resolv.conf (network-manager module) or /run/net-*.conf
# (network-legacy). Copy the first one that has content.
for candidate in /tmp/net.*.resolv.conf /run/net-*.conf; do
    [ -e "$candidate" ] || continue
    case "$candidate" in
        *.resolv.conf)
            cp "$candidate" "${upper}/etc/resolv.conf"
            _pixie_trace "mount hook: wrote resolv.conf from ${candidate}"
            break
            ;;
        /run/net-*.conf)
            # shellcheck disable=SC1090
            . "$candidate" 2>/dev/null || continue
            [ -n "${DNSSERVERS:-}" ] || continue
            {
                echo "# Written by nosi pixie-ramboot dracut hook from ${candidate}."
                [ -n "${DOMAINSEARCH:-}" ] && echo "search ${DOMAINSEARCH}"
                for _ns in ${DNSSERVERS}; do
                    echo "nameserver ${_ns}"
                done
            } > "${upper}/etc/resolv.conf"
            _pixie_trace "mount hook: wrote resolv.conf from ${candidate}"
            break
            ;;
    esac
done

_pixie_status "ramboot.up"
_pixie_trace "mount hook: done -- /sysroot is ${persist:+rw-nbd}${persist:-overlay-on-nbd}"
