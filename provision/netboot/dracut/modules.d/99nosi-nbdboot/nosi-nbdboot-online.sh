#!/bin/sh
# dracut initqueue/online hook for nosi nbdboot (priority 20).
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

_nosi_trace() { echo "nosi-nbdboot: $*" >/dev/kmsg 2>/dev/null || echo "nosi-nbdboot: $*"; }
_nosi_die() {
    _nosi_trace "FATAL: $*"
    type emergency_shell >/dev/null 2>&1 && emergency_shell "nosi-nbdboot: $*"
    exec sleep 2147483647
}

# Idempotent: initqueue/online can fire multiple times as the network
# module reports readiness on each carrier event. Attach once.
[ -e /tmp/nosi-nbd-attached ] && return 0

nbd_url="$(getarg bty.nbd=)"
[ -n "$nbd_url" ] || return 0
image="$(getarg bty.image=)"
[ -n "$image" ] || _nosi_die "missing bty.image on kernel cmdline"

# tcp://host:port -> host, port.
nbd_host="${nbd_url#tcp://}"; nbd_host="${nbd_host%%:*}"
nbd_port="${nbd_url##*:}"

_nosi_trace "online hook: modprobe nbd (nbds_max=1 max_part=16) + overlay"
rmmod nbd 2>/dev/null || true
modprobe nbd nbds_max=1 max_part=16 || _nosi_die "modprobe nbd failed"
modprobe overlay || _nosi_die "modprobe overlay failed"

# nbd-client argument shape: modern nbd-client requires flag options
# BEFORE positional (host, port, device). ``-N NAME`` selects the
# newstyle export name; ``-persist`` re-connects on drop; ``-block-size
# 4096`` avoids the mis-sized-io warnings some kernels emit. Capture
# stderr into a scratch file we can log if the connect fails.
_nosi_trace "online hook: nbd-client -N ${image} -persist ${nbd_host} ${nbd_port} /dev/nbd0"
# TCP-level pre-check: some initrds see nbd-client return before it
# has actually made a syscall; wrap the real attempt in a retry loop
# so a single lost SYN doesn't drop us to emergency.
attempt=0
while [ "$attempt" -lt 5 ]; do
    nbd_out="$(nbd-client -N "$image" -persist "$nbd_host" "$nbd_port" /dev/nbd0 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        break
    fi
    _nosi_trace "online hook: nbd-client attempt $((attempt + 1)) rc=${rc}: ${nbd_out}"
    attempt=$((attempt + 1))
    sleep 1
done
[ "$rc" -eq 0 ] || _nosi_die "nbd-client failed to connect to ${nbd_host}:${nbd_port} after ${attempt} tries: ${nbd_out}"

# Capacity ready.
i=0
while [ "$i" -lt 100 ]; do
    sz="$(blockdev --getsize64 /dev/nbd0 2>/dev/null || echo 0)"
    [ "${sz:-0}" -gt 0 ] && break
    sleep 0.1
    i=$((i + 1))
done
_nosi_trace "online hook: nbd0 capacity ready after ${i} tick(s): ${sz:-0} bytes"

# Pixie's nbdkit serves a single partition (--filter=partition
# partition=1), so /dev/nbd0 is ALREADY the root filesystem: no
# partition table, no /dev/nbd0pN nodes, mount /dev/nbd0 directly.
# We settle udev anyway so the block device is fully published
# before the mount hook fires.
udevadm settle --timeout=10 || true

: > /tmp/nosi-nbd-attached  # pure-shell truncate, no ``touch`` dep (busybox in initrd may lack it)
_nosi_trace "online hook: done -- /dev/nbd0 attached"
