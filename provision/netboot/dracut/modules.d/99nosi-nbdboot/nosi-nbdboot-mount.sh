#!/bin/sh
# dracut mount hook for nosi nbdboot (priority 90).
#
# Runs after ``nosi-nbdboot-online.sh`` has attached /dev/nbd0 and
# after dracut's built-in mount hooks have (attempted to) mount
# /sysroot. Our job here is to:
#
#   1. Pick the largest partition on /dev/nbd0 as root (same
#      heuristic as the initramfs-tools variant).
#   2. Mount it read-only at /run/nosi-lower.
#   3. Mount tmpfs at /run/nosi-upper for the overlay upper+work.
#   4. Overlay-mount at /sysroot so the pivot lands in a writable
#      view of the image without dirtying the shared backing blob.
#   5. Rewrite /etc/fstab in the overlay upper to drop /boot +
#      /boot/efi entries (they'd race jbd2 over the loop stack).
#   6. Mask systemd-networkd + cloud-init in the overlay upper so
#      userspace doesn't tear down the NIC the initrd owns.
#   7. Propagate DNS from dracut's netroot config.

# shellcheck disable=SC1091
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

_nosi_trace() { echo "nosi-nbdboot: $*" >/dev/kmsg 2>/dev/null || echo "nosi-nbdboot: $*"; }
_nosi_die() {
    _nosi_trace "FATAL: $*"
    type emergency_shell >/dev/null 2>&1 && emergency_shell "nosi-nbdboot: $*"
    exec sleep 2147483647
}

nbd_url="$(getarg bty.nbd=)"
[ -n "$nbd_url" ] || return 0
overlay_size="$(getarg bty.overlay_size=)"
root_part_override="$(getarg bty.root_part=)"
: "${overlay_size:=10G}"

[ -b /dev/nbd0 ] || _nosi_die "mount hook: /dev/nbd0 missing (online hook didn't run?)"

# Pixie's nbdkit serves the disk with --filter=partition partition=1
# already applied, so /dev/nbd0 is the ext4 root filesystem. The
# ``bty.root_part=`` override is retained for the legacy full-disk
# case (nbdmux + non-pixie servers that don't partition-filter).
if [ -n "$root_part_override" ]; then
    root_part="$root_part_override"
else
    root_part=/dev/nbd0
fi
_nosi_trace "mount hook: picked root_part=${root_part}"
[ -b "$root_part" ] || _nosi_die "root_part ${root_part} is not a block device"

# dracut may have partially mounted /sysroot already from an earlier
# mount hook trying the baked root=UUID; unmount cleanly so the
# overlay lands on a clean directory. ``umount`` on a not-mounted
# path returns non-zero which we ignore; ``mountpoint`` isn't
# always in the initrd's busybox, so we can't gate on it.
umount /sysroot 2>/dev/null || true

mkdir -p /run/nosi-lower /run/nosi-upper
mnt_rc=1
for fstype in ext4 xfs btrfs auto; do
    _nosi_trace "mount hook: mount -t ${fstype} -o ro ${root_part} -> /run/nosi-lower"
    if mount -t "$fstype" -o ro "$root_part" /run/nosi-lower 2>/dev/null; then
        mnt_rc=0
        break
    fi
done
[ "$mnt_rc" -eq 0 ] || _nosi_die "failed to mount ${root_part}"

_nosi_trace "mount hook: tmpfs(${overlay_size}) -> /run/nosi-upper"
mount -t tmpfs -o "size=${overlay_size}" tmpfs /run/nosi-upper \
    || _nosi_die "failed to mount tmpfs"
mkdir -p /run/nosi-upper/up /run/nosi-upper/work

_nosi_trace "mount hook: overlay -> /sysroot"
mkdir -p /sysroot
mount -t overlay overlay \
    -o "lowerdir=/run/nosi-lower,upperdir=/run/nosi-upper/up,workdir=/run/nosi-upper/work" \
    /sysroot \
    || _nosi_die "failed to mount overlayfs at /sysroot"

# Replace /etc/fstab in the overlay upper with a minimal one.
# The image's fstab lists / (by LABEL cloudimg-rootfs), /boot, and
# /boot/efi entries; letting systemd-fstab-generator materialise
# any of them adds ordering deps on /dev/disk/by-uuid/* nodes that
# never appear (we're not on a disk with a partition table anymore).
# / is already mounted as the overlay from initrd -- fstab has no
# more work to do.
mkdir -p /run/nosi-upper/up/etc
cat > /run/nosi-upper/up/etc/fstab <<EOF
# Written by nosi-nbdboot dracut hook -- nbdboot overrides the
# image's baked /etc/fstab. / is already the initrd's overlay.
EOF
_nosi_trace "mount hook: wrote minimal /etc/fstab in overlay upper"

# Mask systemd-networkd + cloud-init in overlay upper so they don't
# tear down the NIC dracut's network module set up (we still own it
# from the initrd side).
mkdir -p /run/nosi-upper/up/etc/systemd/system
for unit in \
    systemd-networkd.service \
    systemd-networkd.socket \
    systemd-networkd-wait-online.service \
    cloud-init.service \
    cloud-init-local.service \
    cloud-config.service \
    cloud-final.service \
; do
    ln -sf /dev/null "/run/nosi-upper/up/etc/systemd/system/${unit}"
done
_nosi_trace "mount hook: masked networkd + cloud-init in overlay upper"

# Propagate DNS from dracut's netroot config. dracut writes DNS to
# /tmp/net.*.resolv.conf (network-manager module) or /run/net-*.conf
# (network-legacy). Copy the first one that has content.
for candidate in /tmp/net.*.resolv.conf /run/net-*.conf; do
    [ -e "$candidate" ] || continue
    case "$candidate" in
        *.resolv.conf)
            cp "$candidate" /run/nosi-upper/up/etc/resolv.conf
            _nosi_trace "mount hook: wrote resolv.conf from ${candidate}"
            break
            ;;
        /run/net-*.conf)
            # shellcheck disable=SC1090
            . "$candidate" 2>/dev/null || continue
            [ -n "${DNSSERVERS:-}" ] || continue
            {
                echo "# Written by nosi-nbdboot dracut hook from ${candidate}."
                [ -n "${DOMAINSEARCH:-}" ] && echo "search ${DOMAINSEARCH}"
                for _ns in ${DNSSERVERS}; do
                    echo "nameserver ${_ns}"
                done
            } > /run/nosi-upper/up/etc/resolv.conf
            _nosi_trace "mount hook: wrote resolv.conf from ${candidate}"
            break
            ;;
    esac
done

# Best-effort status POST so the timeline reflects "ramboot.up"
# before pivot. Silent on failure.
server="$(getarg bty.server=)"
mac="$(getarg bty.mac=)"
if [ -n "$server" ] && [ -n "$mac" ]; then
    wget -q -O /dev/null \
        --post-data="status=ramboot.up" \
        "${server}/pxe/${mac}/status" || true
fi

_nosi_trace "mount hook: done -- /sysroot is overlay-on-nbd"
