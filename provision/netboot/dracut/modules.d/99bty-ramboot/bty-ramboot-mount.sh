#!/bin/sh
# dracut mount hook for bty ramboot (priority 90).
#
# Runs after ``bty-ramboot-online.sh`` has attached /dev/nbd0 and
# after dracut's built-in mount hooks have (attempted to) mount
# /sysroot. Our job here is to:
#
#   1. Pick the largest partition on /dev/nbd0 as root (same
#      heuristic as the initramfs-tools variant).
#   2. Mount it read-only at /run/bty-lower.
#   3. Mount tmpfs at /run/bty-upper for the overlay upper+work.
#   4. Overlay-mount at /sysroot so the pivot lands in a writable
#      view of the image without dirtying the shared backing blob.
#   5. Rewrite /etc/fstab in the overlay upper to drop /boot +
#      /boot/efi entries (they'd race jbd2 over the loop stack).
#   6. Mask systemd-networkd + cloud-init in the overlay upper so
#      userspace doesn't tear down the NIC the initrd owns.
#   7. Propagate DNS from dracut's netroot config.

# shellcheck disable=SC1091
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

_bty_trace() { echo "bty-ramboot: $*" >/dev/kmsg 2>/dev/null || echo "bty-ramboot: $*"; }
_bty_die() {
    _bty_trace "FATAL: $*"
    type emergency_shell >/dev/null 2>&1 && emergency_shell "bty-ramboot: $*"
    exec sleep 2147483647
}

nbd_url="$(getarg bty.nbd=)"
[ -n "$nbd_url" ] || return 0
overlay_size="$(getarg bty.overlay_size=)"
root_part_override="$(getarg bty.root_part=)"
: "${overlay_size:=10G}"

[ -b /dev/nbd0 ] || _bty_die "mount hook: /dev/nbd0 missing (online hook didn't run?)"

# The online hook attaches nbd0 + kicks partx, but partition device
# nodes can trickle in a few hundred ms later via udev. Wait briefly
# for them before we sort by size.
i=0
while [ "$i" -lt 40 ]; do
    [ -b /dev/nbd0p1 ] && break
    sleep 0.1
    i=$((i + 1))
done
_bty_trace "mount hook: nbd0 partition nodes: $(ls /dev/nbd0p* 2>/dev/null | tr '\n' ' ' || echo '<none>')"

if [ -n "$root_part_override" ]; then
    root_part="$root_part_override"
elif [ -b /dev/nbd0p1 ]; then
    root_part="$(
        for p in /dev/nbd0p*; do
            [ -b "$p" ] && echo "$(blockdev --getsize64 "$p") $p"
        done | sort -n | tail -1 | cut -d' ' -f2
    )"
else
    root_part=/dev/nbd0
fi
_bty_trace "mount hook: picked root_part=${root_part}"
[ -n "$root_part" ] && [ -e "$root_part" ] || _bty_die "no root partition on /dev/nbd0"

# dracut may have partially mounted /sysroot already from an earlier
# mount hook trying the baked root=UUID; unmount cleanly so the
# overlay lands on a clean directory. ``umount`` on a not-mounted
# path returns non-zero which we ignore; ``mountpoint`` isn't
# always in the initrd's busybox, so we can't gate on it.
umount /sysroot 2>/dev/null || true

mkdir -p /run/bty-lower /run/bty-upper
mnt_rc=1
for fstype in ext4 xfs btrfs auto; do
    _bty_trace "mount hook: mount -t ${fstype} -o ro ${root_part} -> /run/bty-lower"
    if mount -t "$fstype" -o ro "$root_part" /run/bty-lower 2>/dev/null; then
        mnt_rc=0
        break
    fi
done
[ "$mnt_rc" -eq 0 ] || _bty_die "failed to mount ${root_part}"

_bty_trace "mount hook: tmpfs(${overlay_size}) -> /run/bty-upper"
mount -t tmpfs -o "size=${overlay_size}" tmpfs /run/bty-upper \
    || _bty_die "failed to mount tmpfs"
mkdir -p /run/bty-upper/up /run/bty-upper/work

_bty_trace "mount hook: overlay -> /sysroot"
mkdir -p /sysroot
mount -t overlay overlay \
    -o "lowerdir=/run/bty-lower,upperdir=/run/bty-upper/up,workdir=/run/bty-upper/work" \
    /sysroot \
    || _bty_die "failed to mount overlayfs at /sysroot"

# Strip /boot + /boot/efi from fstab in overlay upper -- systemd
# would otherwise try to mount them off the image's partition table
# and race jbd2 over the loop stack.
if [ -e /run/bty-lower/etc/fstab ]; then
    mkdir -p /run/bty-upper/up/etc
    awk '$2 != "/boot" && $2 != "/boot/efi" { print }' \
        /run/bty-lower/etc/fstab > /run/bty-upper/up/etc/fstab
    _bty_trace "mount hook: rewrote /etc/fstab in overlay upper"
fi

# Mask systemd-networkd + cloud-init in overlay upper so they don't
# tear down the NIC dracut's network module set up (we still own it
# from the initrd side).
mkdir -p /run/bty-upper/up/etc/systemd/system
for unit in \
    systemd-networkd.service \
    systemd-networkd.socket \
    systemd-networkd-wait-online.service \
    cloud-init.service \
    cloud-init-local.service \
    cloud-config.service \
    cloud-final.service \
; do
    ln -sf /dev/null "/run/bty-upper/up/etc/systemd/system/${unit}"
done
_bty_trace "mount hook: masked networkd + cloud-init in overlay upper"

# Propagate DNS from dracut's netroot config. dracut writes DNS to
# /tmp/net.*.resolv.conf (network-manager module) or /run/net-*.conf
# (network-legacy). Copy the first one that has content.
for candidate in /tmp/net.*.resolv.conf /run/net-*.conf; do
    [ -e "$candidate" ] || continue
    case "$candidate" in
        *.resolv.conf)
            cp "$candidate" /run/bty-upper/up/etc/resolv.conf
            _bty_trace "mount hook: wrote resolv.conf from ${candidate}"
            break
            ;;
        /run/net-*.conf)
            # shellcheck disable=SC1090
            . "$candidate" 2>/dev/null || continue
            [ -n "${DNSSERVERS:-}" ] || continue
            {
                echo "# Written by nosi bty-ramboot dracut hook from ${candidate}."
                [ -n "${DOMAINSEARCH:-}" ] && echo "search ${DOMAINSEARCH}"
                for _ns in ${DNSSERVERS}; do
                    echo "nameserver ${_ns}"
                done
            } > /run/bty-upper/up/etc/resolv.conf
            _bty_trace "mount hook: wrote resolv.conf from ${candidate}"
            break
            ;;
    esac
done

# Best-effort status POST so bty's timeline reflects "ramboot up"
# before pivot. Silent on failure.
server="$(getarg bty.server=)"
mac="$(getarg bty.mac=)"
if [ -n "$server" ] && [ -n "$mac" ]; then
    wget -q -O /dev/null \
        --post-data="status=ramboot.up" \
        "${server}/pxe/${mac}/status" || true
fi

_bty_trace "mount hook: done -- /sysroot is overlay-on-nbd"
