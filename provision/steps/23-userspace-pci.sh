#!/usr/bin/env bash
# nosi/provision/steps/23-userspace-pci.sh
#
# User space PCI prerequisites for passing devices through to qemu guests
# or to podman containers (DPDK/SPDK and xNVMe/uPCIe workloads, GPU-style
# passthrough, etc.):
#
#   * /etc/modules-load.d/nosi-userspace-pci.conf: preload vfio-pci +
#     uio_pci_generic so devices can be bound to a user space driver
#     immediately, with the package that carries uio_pci_generic installed
#     where a cloud kernel leaves it out (Ubuntu 24.04, Fedora).
#   * /etc/udev/rules.d/99-nosi-vfio.rules: hand /dev/vfio/* to the kvm
#     group, which odus is in, so passthrough works without sudo.
#   * /etc/security/limits.d/nosi-memlock.conf: raise RLIMIT_MEMLOCK to
#     unlimited system-wide. VFIO_IOMMU_MAP_DMA pins user space pages
#     against this limit; the stock Debian/Ubuntu 64 MiB ceiling is the
#     exact threshold below which `devbind --list` fires its
#     memlock-too-low diagnostic.
#
# Hugepages are intentionally NOT reserved at provision time (right count
# depends on host RAM and workload); set at runtime with e.g.
# `sudo sysctl -w vm.nr_hugepages=512` for 1 GiB of 2 MiB pages, or via
# the `hugepages` helper from step 22.
#
# IOMMU enablement on the kernel cmdline (intel_iommu=on amd_iommu=on
# iommu=pt) is per-distro (grub vs grubby) and stays in the per-shape
# cloud-init runcmd for now.
#
# Idempotency: nosi_write_if_changed only touches mtime when content
# differs.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 23-userspace-pci"
nosi_require_root

# ---- preload vfio-pci + uio_pci_generic -----------------------------------

nosi_write_if_changed \
'# Managed by nosi/provision/steps/23-userspace-pci.sh
vfio-pci
uio_pci_generic
' /etc/modules-load.d/nosi-userspace-pci.conf 0644

# Cloud images ship a kernel cut down to what a VM boots on, leaving
# uio_pci_generic out, so the preload above binds nothing: Ubuntu 24.04's
# linux-virtual keeps it in linux-modules-extra, Fedora's cloud image in
# kernel-modules. The running kernel gets the package, and a metapackage
# that brings it with every kernel an upgrade installs.
if ! modinfo uio_pci_generic >/dev/null 2>&1; then
    case "$NOSI_DISTRO" in
    ubuntu) nosi_pkg_install "linux-modules-extra-$(uname -r)" linux-image-generic ;;
    fedora) nosi_pkg_install "kernel-modules-$(uname -r)" kernel ;;
    esac
fi

# ---- /dev/vfio/* group ownership ------------------------------------------

nosi_write_if_changed \
'# Managed by nosi/provision/steps/23-userspace-pci.sh
# /dev/vfio/* accessible to the kvm group so vfio passthrough works
# for unprivileged users in that group (qemu -device vfio-pci=... ,
# podman --device=/dev/vfio/N ...).
SUBSYSTEM=="vfio", OWNER="root", GROUP="kvm", MODE="0660"
' /etc/udev/rules.d/99-nosi-vfio.rules 0644

# ---- memlock soft+hard = unlimited ----------------------------------------

nosi_write_if_changed \
'# Managed by nosi/provision/steps/23-userspace-pci.sh
# Debian/Ubuntu stock pam_limits.so applies the `*` domain to non-root
# sessions only, so root keeps the ~64 KiB default. DPDK mlock()s its
# hugepage region as root and SPDK then bails (xnvme_dev_open errno -6);
# the explicit `root` lines lift the cap for root sessions too.
*    soft  memlock  unlimited
*    hard  memlock  unlimited
root soft  memlock  unlimited
root hard  memlock  unlimited
' /etc/security/limits.d/nosi-memlock.conf 0644

nosi_info "step 23-userspace-pci done"
