#!/usr/bin/env bash
# nosi/provision/steps/34-netboot-nbdboot-hook.sh
#
# Bake the nbdboot attach-hook into the image's initrd so the same
# disk image can either flash-boot locally (hook inert) OR netboot from
# NBD (hook fires when ``bty.nbd=`` is on the kernel cmdline).
#
# Historically the netboot chain used to load a bty-media-baked
# kernel+initrd (Debian 6.12) regardless of the image's own kernel
# version, causing ``uname -r`` under nbdboot to not match the
# image's ``/lib/modules/`` tree; any driver not in bty-media's
# kernel was unloadable in the netbooted guest (r8125 DKMS, nvidia,
# custom hypervisor stacks, ...).
# Shifting the hook-install to build time here means the initrd we ship
# in the image carries the ATTACH machinery + the correct kernel
# modules for the image's own kernel; bty just fetches the extracted
# vmlinuz + initrd at netboot time.
#
# Two frameworks:
#
#   initramfs-tools (Debian / Ubuntu-22.04 etc.): drop /scripts/nbdboot
#     driver + hooks/nosi-nbdboot into /etc/initramfs-tools/, then
#     ``update-initramfs -u -k all``. Boot dispatch is
#     initramfs-tools' /init reading ``boot=nbdboot`` from cmdline.
#
#   dracut (Fedora / Ubuntu-26.04+): install a 99nosi-nbdboot module
#     under /usr/lib/dracut/modules.d/, and force the stock ``nbd``
#     module + nbd/overlay drivers into every initrd via
#     /etc/dracut.conf.d/99-nosi-netboot.conf. Then
#     ``dracut --regenerate-all --force``. Boot dispatch is the module's
#     mount-hook reading ``bty.nbd=`` from cmdline.
#
# Non-headless shapes (desktop / wsl / lxc / docker / proxmox) skip
# entirely: netboot isn't a shape that ever matters for those.
# Non-Linux (FreeBSD) skips too -- kernel + initrd chain diverge and a
# BSD story is a separate design.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 34-netboot-nbdboot-hook (distro=$NOSI_DISTRO shape=${NOSI_SHAPE:-headless})"
nosi_require_root

# Only headless images become bootable-from-network. desktop shapes
# might make sense for game-streaming appliances later but are out of
# scope now; wsl/lxc/docker have no kernel of their own; proxmox is a
# hypervisor host, flash-only.
if [ -n "${NOSI_SHAPE:-}" ] && [ "${NOSI_SHAPE}" != "headless" ]; then
    nosi_info "shape=${NOSI_SHAPE} is not headless; skipping"
    exit 0
fi

if [ "$NOSI_DISTRO" = "freebsd" ]; then
    nosi_info "freebsd netboot is a separate design; skipping"
    exit 0
fi

HERE="$(dirname "$(readlink -f "$0")")"
ASSETS="$HERE/../netboot"

case "$NOSI_PKGMGR" in
    apt)
        # initramfs-tools path. busybox-static ships the tiny statically-
        # linked busybox that the /scripts/nbdboot driver reaches for
        # (sleep 0.1 polls, ip addr show, awk, ...). Stock Debian cloud
        # images don't include it; drop it in before update-initramfs so
        # the hook can ``copy_exec /usr/bin/busybox``.
        nosi_pkg_install nbd-client busybox-static
        install -d -m 0755 /etc/initramfs-tools/scripts /etc/initramfs-tools/hooks
        install -m 0644 "$ASSETS/initramfs-tools/scripts/nbdboot" /etc/initramfs-tools/scripts/nbdboot
        install -m 0755 "$ASSETS/initramfs-tools/hooks/nosi-nbdboot" /etc/initramfs-tools/hooks/nosi-nbdboot
        nosi_info "regenerating all initramfs images (update-initramfs -u -k all)"
        update-initramfs -u -k all
        ;;
    dnf)
        # dracut path (Fedora).
        # ``nbd`` binary is in the stock ``nbd`` package on Fedora.
        # ``dracut-network`` ships the network-manager + nbd dracut
        # modules our conf.d references; without it the minimal
        # cloud-image dracut has only base modules and the
        # ``network-manager`` dep on our module fails to resolve.
        nosi_pkg_install nbd dracut-network
        install -d -m 0755 /etc/dracut.conf.d /usr/lib/dracut/modules.d/99nosi-nbdboot
        install -m 0644 "$ASSETS/dracut/conf.d/99-nosi-netboot.conf" /etc/dracut.conf.d/99-nosi-netboot.conf
        install -m 0755 "$ASSETS/dracut/modules.d/99nosi-nbdboot/module-setup.sh" /usr/lib/dracut/modules.d/99nosi-nbdboot/module-setup.sh
        # Three phased runtime hooks replace the old single ``nosi-nbdboot.sh``
        # so the cmdline override lands before initqueue's baked root=UUID
        # devexists polls and the mount phase runs after online has attached
        # /dev/nbd0. See module-setup.sh for the full contract.
        install -m 0755 "$ASSETS/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-cmdline.sh" /usr/lib/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-cmdline.sh
        install -m 0755 "$ASSETS/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-online.sh" /usr/lib/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-online.sh
        install -m 0755 "$ASSETS/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-mount.sh" /usr/lib/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-mount.sh
        nosi_info "regenerating all initramfs images (dracut --regenerate-all --force)"
        dracut --regenerate-all --force
        ;;
    *)
        nosi_warn "unsupported package manager for netboot hook (NOSI_PKGMGR=$NOSI_PKGMGR); skipping"
        exit 0
        ;;
esac

# Ubuntu 26.04 ships dracut instead of initramfs-tools even though
# NOSI_PKGMGR=apt. Detect that ex post: if /etc/dracut.conf.d exists
# AND dracut is the effective initrd generator, we should have taken
# the dnf path above; run the dracut wiring on top.
#
# This branch fires only when the box is apt-based BUT dracut-driven.
# We do it after the initramfs-tools wiring so update-initramfs -u
# above still runs (harmless on dracut hosts) and the dracut modules
# then take precedence.
if [ "$NOSI_PKGMGR" = "apt" ] && command -v dracut >/dev/null 2>&1 && [ -d /etc/dracut.conf.d ]; then
    nosi_info "apt-based host with dracut detected; also wiring dracut module"
    nosi_pkg_install nbd-client
    install -d -m 0755 /usr/lib/dracut/modules.d/99nosi-nbdboot
    install -m 0644 "$ASSETS/dracut/conf.d/99-nosi-netboot.conf" /etc/dracut.conf.d/99-nosi-netboot.conf
    install -m 0755 "$ASSETS/dracut/modules.d/99nosi-nbdboot/module-setup.sh" /usr/lib/dracut/modules.d/99nosi-nbdboot/module-setup.sh
    install -m 0755 "$ASSETS/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-cmdline.sh" /usr/lib/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-cmdline.sh
    install -m 0755 "$ASSETS/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-online.sh" /usr/lib/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-online.sh
    install -m 0755 "$ASSETS/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-mount.sh" /usr/lib/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-mount.sh
    dracut --regenerate-all --force
fi

nosi_info "step 34-netboot-nbdboot-hook done"
