#!/usr/bin/env bash
# nosi/provision/steps/56-lxc-container.sh
#
# lxc shape only. Adapts the rootfs for life as a system container (Proxmox
# CT / Incus / LXD), where the container shares the host kernel and the
# platform owns first-boot + networking.
#
# Most of the container hygiene is already done by the shape strip in
# derive_pack (it purges the kernel, firmware, cloud-init, netplan and
# NetworkManager for stripped shapes). This step covers what the strip does
# not:
#
#   * nosi-growroot is meaningless in a container (there is no disk/partition
#     to grow); mask it so it does not log a failure on every boot.
#   * with NetworkManager gone, Proxmox configures the container by writing
#     /etc/network/interfaces, so ensure ifupdown is present to apply it.
#
# Like the other shape steps it OWNS its package installs, so
# `apply.sh <distro>-lxc` fully defines the lxc shape on a baked headless
# rootfs (then derive_pack strips + packs the CT tarball).

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 56-lxc-container (shape=${NOSI_SHAPE:-?})"

if [ "${NOSI_SHAPE:-}" != "lxc" ]; then
    nosi_info "non-lxc shape; skipping"
    exit 0
fi

nosi_require_root

# No disk to grow inside a container.
systemctl mask nosi-growroot.service 2>/dev/null || true

case "${NOSI_PKGMGR:-}" in
apt)
    # Proxmox writes /etc/network/interfaces for Debian/Ubuntu CTs; ifupdown
    # applies it. (Fedora CTs are driven via systemd-networkd, already present.)
    nosi_pkg_install ifupdown
    ;;
dnf)
    : # Fedora: Proxmox drives the CT via systemd-networkd; nothing to add.
    ;;
*)
    nosi_die "lxc shape supports apt/dnf distros only; got pkgmgr=${NOSI_PKGMGR:-?}"
    ;;
esac

nosi_info "step 56-lxc-container done"
