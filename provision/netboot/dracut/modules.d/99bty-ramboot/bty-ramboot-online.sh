#!/bin/sh
# dracut initqueue/online hook for bty ramboot (priority 20).
#
# Runs after the ``network`` module has brought the primary NIC up
# with DHCP. This is when we can finally reach the NBD server.
# Attaches ``/dev/nbd0`` to the remote export named in ``bty.image=``,
# waits for capacity + partition nodes, then returns; dracut's
# initqueue polling sees /dev/nbd0 appear and advances.
#
# Overlay + fstab rewrite + resolv.conf population land in the
# subsequent ``mount`` phase hook so we don't block initqueue on
# tasks that need the block device to be settled first.

# shellcheck disable=SC1091
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

_bty_trace() { echo "bty-ramboot: $*" >/dev/kmsg 2>/dev/null || echo "bty-ramboot: $*"; }
_bty_die() {
    _bty_trace "FATAL: $*"
    type emergency_shell >/dev/null 2>&1 && emergency_shell "bty-ramboot: $*"
    exec sleep 2147483647
}

# Idempotent: initqueue/online can fire multiple times as the network
# module reports readiness on each carrier event. Attach once.
[ -e /tmp/bty-nbd-attached ] && return 0

nbd_url="$(getarg bty.nbd=)"
[ -n "$nbd_url" ] || return 0
image="$(getarg bty.image=)"
[ -n "$image" ] || _bty_die "missing bty.image on kernel cmdline"

# tcp://host:port -> host, port.
nbd_host="${nbd_url#tcp://}"; nbd_host="${nbd_host%%:*}"
nbd_port="${nbd_url##*:}"

_bty_trace "online hook: modprobe nbd (nbds_max=1 max_part=16) + overlay"
rmmod nbd 2>/dev/null || true
modprobe nbd nbds_max=1 max_part=16 || _bty_die "modprobe nbd failed"
modprobe overlay || _bty_die "modprobe overlay failed"

_bty_trace "online hook: nbd-client -persist ${nbd_host}:${nbd_port} -name ${image}"
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
_bty_trace "online hook: nbd0 capacity ready after ${i} tick(s): ${sz:-0} bytes"

# Partition scan is racy on nbd; fall back to userspace partx if
# the kernel didn't emit the partition uevents in time.
udevadm settle --timeout=10 || true
blockdev --rereadpt /dev/nbd0 2>/dev/null || true
udevadm settle --timeout=10 || true

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

: > /tmp/bty-nbd-attached  # pure-shell truncate, no ``touch`` dep (busybox in initrd may lack it)
_bty_trace "online hook: done -- /dev/nbd0 attached"
