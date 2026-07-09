#!/bin/bash
# dracut module: bty-ramboot
#
# Install-time hook. Called by ``dracut -f`` (or dracut's automatic
# runs after a kernel update) when 99bty-ramboot is in the module
# list (pulled in by /etc/dracut.conf.d/99-nosi-netboot.conf on
# nosi-baked images). Wires up:
#
#   * kernel modules (nbd, overlay, ext4/xfs/btrfs) so the runtime
#     hook doesn't have to modprobe from userspace with a missing
#     dep chain.
#   * userspace binaries (nbd-client + core utilities used by the
#     runtime hook) baked into the initrd tree.
#   * ``bty-ramboot.sh`` as a ``mount`` hook -- dracut's mount phase
#     is where /sysroot gets populated, which is our overlay-on-nbd
#     stack. Priority 10 places us early, before any distro-shipped
#     mount hooks (typical priorities are 90-99).

# shellcheck disable=SC2148

# check() = 255 -> the module is only added when explicitly listed
# in add_dracutmodules= or by kernel cmdline. Nosi does the former.
# Return 0 would auto-add on every host; that's too eager for a
# module that only makes sense in netbooted contexts.
check() {
    return 255
}

# The runtime hook depends on the base + network dracut modules to
# initialize DHCP + resolv.conf before nbd-client tries to connect.
depends() {
    echo "base network"
    return 0
}

# Kernel modules pulled into the initrd. ``instmods`` silently
# ignores modules not built for this kernel, which is what we want:
# btrfs may or may not be available; the runtime hook probes
# opportunistically.
installkernel() {
    instmods nbd overlay ext4 xfs btrfs
}

# Userspace: nbd-client + the shell tooling the runtime hook uses.
# ``inst_multiple`` resolves ELF interpreter + shared-lib closures
# via ldd; ``inst_hook`` copies the runtime script into the initrd's
# hook directory for the given phase.
install() {
    inst_multiple nbd-client mount umount awk sed grep sort cut wget \
                  blockdev partx udevadm blkid ip
    # ``$moddir`` is exported by dracut when it sources this file --
    # it points at the module's own directory.
    # shellcheck disable=SC2154
    inst_hook mount 10 "$moddir/bty-ramboot.sh"
}
