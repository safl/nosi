#!/bin/sh
# dracut mount-hook for bty ramboot.
#
# Called during dracut's ``mount`` phase (after the ``network`` module
# has DHCP'd the primary NIC and after udev has settled). Reads
# ``bty.nbd=`` / ``bty.image=`` / ``bty.overlay_size=`` from the
# kernel cmdline; if unset, no-ops (the image is booting locally, not
# via ramboot).
#
# Sequence:
#   1. Parse bty.* params. No params -> return; leave /sysroot for
#      dracut's other mount hooks (the normal local-disk root path).
#   2. modprobe nbd + overlay (drivers were pulled in by
#      module-setup.sh; this is the load).
#   3. nbd-client -persist attaches /dev/nbd0 to nbdmux.
#   4. Wait for capacity + partition nodes.
#   5. Pick the largest partition on /dev/nbd0 as root (matches
#      the heuristic in the initramfs-tools driver).
#   6. Mount root RO on /run/bty-lower.
#   7. Mount tmpfs on /run/bty-upper.
#   8. Overlay-mount at /sysroot (lower=/run/bty-lower,
#      upper=/run/bty-upper/up, work=/run/bty-upper/work).
#   9. Strip /boot + /boot/efi from /sysroot/etc/fstab in the overlay
#      upper so systemd doesn't try to mount them off the image's
#      partition table (would race jbd2 over the loop stack).
#  10. Mask systemd-networkd + cloud-init in the overlay upper so
#      userspace doesn't tear down the NIC the initrd owns.
#  11. Propagate DNS from dracut's netroot config so the pivoted root
#      can resolve names.

# shellcheck disable=SC1091
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

_bty_trace() { echo "bty-ramboot: $*" >/dev/kmsg 2>/dev/null || echo "bty-ramboot: $*"; }

_bty_die() {
    _bty_trace "FATAL: $*"
    # emergency_shell is dracut's rescue-shell entry; falls back to
    # sleep-forever if it returns.
    type emergency_shell >/dev/null 2>&1 && emergency_shell "bty-ramboot: $*"
    exec sleep 2147483647
}

nbd_url="$(getarg bty.nbd=)"
[ -n "$nbd_url" ] || return 0
image="$(getarg bty.image=)"
overlay_size="$(getarg bty.overlay_size=)"
root_part_override="$(getarg bty.root_part=)"
: "${overlay_size:=10G}"

_bty_trace "cmdline nbd=${nbd_url} image=${image:-<unset>} overlay_size=${overlay_size}"
if [ -z "$image" ]; then
    _bty_die "missing bty.image on kernel cmdline"
fi

# tcp://host:port -> host, port.
nbd_host="${nbd_url#tcp://}"; nbd_host="${nbd_host%%:*}"
nbd_port="${nbd_url##*:}"

_bty_trace "modprobe nbd (nbds_max=1 max_part=16) + overlay"
rmmod nbd 2>/dev/null || true
modprobe nbd nbds_max=1 max_part=16 || _bty_die "modprobe nbd failed"
modprobe overlay || _bty_die "modprobe overlay failed"

_bty_trace "nbd-client -persist ${nbd_host}:${nbd_port} -name ${image}"
if ! nbd-client -persist "$nbd_host" "$nbd_port" -name "$image" /dev/nbd0; then
    _bty_die "nbd-client failed to connect to ${nbd_host}:${nbd_port}"
fi

# Capacity ready.
i=0
while [ "$i" -lt 100 ]; do
    sz="$(blockdev --getsize64 /dev/nbd0 2>/dev/null || echo 0)"
    [ "${sz:-0}" -gt 0 ] && break
    sleep 0.1
    i=$((i + 1))
done
_bty_trace "nbd0 capacity ready after ${i} tick(s): ${sz:-0} bytes"

udevadm settle --timeout=10 || true
blockdev --rereadpt /dev/nbd0 2>/dev/null || true
udevadm settle --timeout=10 || true

# Kernel partition scan is racy on nbd; if native didn't produce a
# node, use partx from userspace (same fallback as initramfs-tools).
i=0
while [ "$i" -lt 20 ]; do
    [ -b /dev/nbd0p1 ] && break
    sleep 0.1
    i=$((i + 1))
done
if [ ! -b /dev/nbd0p1 ]; then
    partx --add /dev/nbd0 2>/dev/null || true
    udevadm settle --timeout=10 || true
fi

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
_bty_trace "picked root_part=${root_part:-<none>}"
[ -n "$root_part" ] && [ -e "$root_part" ] || _bty_die "no root partition on /dev/nbd0"

mkdir -p /run/bty-lower /run/bty-upper
mnt_rc=1
for fstype in ext4 xfs btrfs auto; do
    _bty_trace "mount -t ${fstype} -o ro ${root_part} -> /run/bty-lower"
    if mount -t "$fstype" -o ro "$root_part" /run/bty-lower 2>/dev/null; then
        mnt_rc=0
        break
    fi
done
[ "$mnt_rc" -eq 0 ] || _bty_die "failed to mount ${root_part}"

_bty_trace "tmpfs(${overlay_size}) -> /run/bty-upper"
mount -t tmpfs -o "size=${overlay_size}" tmpfs /run/bty-upper \
    || _bty_die "failed to mount tmpfs"
mkdir -p /run/bty-upper/up /run/bty-upper/work

_bty_trace "overlay -> /sysroot"
mkdir -p /sysroot
mount -t overlay overlay \
    -o "lowerdir=/run/bty-lower,upperdir=/run/bty-upper/up,workdir=/run/bty-upper/work" \
    /sysroot \
    || _bty_die "failed to mount overlayfs at /sysroot"

# Strip /boot + /boot/efi from fstab in overlay upper -- same
# rationale as the initramfs-tools variant.
if [ -e /run/bty-lower/etc/fstab ]; then
    mkdir -p /run/bty-upper/up/etc
    awk '$2 != "/boot" && $2 != "/boot/efi" { print }' \
        /run/bty-lower/etc/fstab > /run/bty-upper/up/etc/fstab
    _bty_trace "fstab: rewrote /etc/fstab in overlay upper"
fi

# Mask systemd-networkd + cloud-init in overlay upper.
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
_bty_trace "masked networkd + cloud-init in overlay upper"

# Propagate DNS from dracut's netroot config. dracut writes DNS to
# /tmp/net.*.resolv.conf under the network module; also handles the
# /run/net-*.conf variant that ipconfig (initramfs-tools) writes.
for candidate in /tmp/net.*.resolv.conf /run/net-*.conf; do
    [ -e "$candidate" ] || continue
    case "$candidate" in
        *.resolv.conf)
            cp "$candidate" /run/bty-upper/up/etc/resolv.conf
            _bty_trace "wrote resolv.conf from ${candidate}"
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
            _bty_trace "wrote resolv.conf from ${candidate}"
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

_bty_trace "mount-hook done; /sysroot is overlay-on-nbd"
