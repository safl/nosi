#!/bin/bash
# dracut module: bty-ramboot
#
# Install-time hook. Called by ``dracut -f`` (or dracut's automatic
# runs after a kernel update) when 99bty-ramboot is in the module
# list (pulled in by /etc/dracut.conf.d/99-nosi-netboot.conf on
# nosi-baked images). Wires up:
#
#   * kernel modules (nbd, overlay, ext4/xfs/btrfs) so the runtime
#     hooks don't have to modprobe from userspace with a missing
#     dep chain.
#   * userspace binaries (nbd-client + core utilities used by the
#     runtime hooks) baked into the initrd tree.
#   * Three phased hooks driving the ramboot chain:
#
#     - cmdline (priority 10): parse ``bty.nbd=`` off /proc/cmdline
#       and IMMEDIATELY override dracut's ``root`` var so the
#       initqueue doesn't wait for the image's baked ``root=UUID=``
#       (which never appears -- there's no local disk). Also
#       registers ``/dev/nbd0`` as the wait-for device.
#
#     - initqueue/online (priority 20): after ``network`` module
#       has DHCPed the primary NIC, run nbd-client to attach the
#       remote export at /dev/nbd0. Idempotent (touches a sentinel
#       so re-entry of the initqueue no-ops).
#
#     - mount (priority 90): last-mile pivot prep -- overlay the
#       root partition on tmpfs, rewrite /etc/fstab in the overlay
#       upper (drop /boot + /boot/efi), mask systemd-networkd +
#       cloud-init in the overlay upper, propagate DNS. Runs LAST
#       so dracut's own mount hooks have finished by the time we
#       repoint /sysroot at our overlay.
#
# The old single-hook shape ``inst_hook mount 10`` was fundamentally
# wrong: dracut's mount phase never fires when initqueue is stuck
# waiting for the image's baked ``root=UUID=`` (which never appears
# without our NBD attach). Splitting into cmdline+online+mount lets
# each phase do its job in the order dracut actually runs them.

# shellcheck disable=SC2148

# check() = 255 -> the module is only added when explicitly listed
# in add_dracutmodules= or by kernel cmdline. Nosi does the former.
check() {
    return 255
}

# Runtime deps: base for shell tooling, network-manager for the
# initrd-side DHCP + resolv.conf population that the online hook
# consumes. Fedora 40+ split ``network`` into concrete providers
# (``network-manager``, ``network-legacy``, ``network-wicked``) and
# ``network`` no longer resolves; ``network-manager`` is the
# concrete dep that works on both Fedora 44 and Ubuntu 26.04.
depends() {
    echo "base network-manager"
    return 0
}

# Kernel modules pulled into the initrd. ``instmods`` silently
# ignores modules not built for this kernel, which is what we want:
# btrfs may or may not be available; the runtime hook probes
# opportunistically.
installkernel() {
    instmods nbd overlay ext4 xfs btrfs
}

# Userspace: nbd-client + shell tooling the runtime hooks use.
# ``inst_multiple`` resolves ELF interpreter + shared-lib closures
# via ldd; ``inst_hook`` copies each runtime script into the
# initrd's hook directory for the given phase.
install() {
    inst_multiple nbd-client mount umount awk sed grep sort cut wget \
                  blockdev partx udevadm blkid ip modprobe
    # ``$moddir`` is exported by dracut when it sources this file --
    # it points at the module's own directory.
    # shellcheck disable=SC2154
    inst_hook cmdline 10 "$moddir/bty-ramboot-cmdline.sh"
    inst_hook initqueue/online 20 "$moddir/bty-ramboot-online.sh"
    inst_hook mount 90 "$moddir/bty-ramboot-mount.sh"

    # Ubuntu's cloud-image dracut config bakes root=UUID references
    # into the initrd in three places that all need stripping so
    # dracut doesn't hang for 3 min waiting for local disks that
    # never appear under ramboot:
    #
    #   /etc/cmdline.d/20-root-dev.conf
    #       kernel-cmdline fragment that adds root=UUID= (merged
    #       into effective cmdline before any hook runs).
    #
    #   /var/lib/dracut/hooks/initqueue/finished/devexists-*.sh
    #       initqueue "am I done yet" polls that require the baked
    #       root/boot/EFI UUIDs to appear as block devices.
    #
    #   /var/lib/dracut/hooks/emergency/80-*.sh
    #       emergency shell handlers that fire when the devexists
    #       polls time out.
    #
    # ``initdir`` is exported by dracut when install() runs.
    # shellcheck disable=SC2154
    if [ -d "${initdir}/etc/cmdline.d" ]; then
        [ -e "${initdir}/etc/cmdline.d/20-root-dev.conf" ] && \
            : > "${initdir}/etc/cmdline.d/20-root-dev.conf"
    fi
    if [ -d "${initdir}/var/lib/dracut/hooks/initqueue/finished" ]; then
        rm -f "${initdir}/var/lib/dracut/hooks/initqueue/finished/devexists-"*.sh
    fi
    if [ -d "${initdir}/var/lib/dracut/hooks/emergency" ]; then
        rm -f "${initdir}/var/lib/dracut/hooks/emergency/80-"*.sh
    fi
}
