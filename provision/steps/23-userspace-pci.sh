#!/usr/bin/env bash
# nosi/provision/steps/23-userspace-pci.sh
#
# User space PCI prerequisites for passing devices through to qemu guests
# or to podman containers (DPDK/SPDK and xNVMe/uPCIe workloads, GPU-style
# passthrough, etc.):
#
#   * /etc/modules-load.d/nosi-userspace-pci.conf: preload vfio-pci +
#     uio_pci_generic so devices can be bound to a user space driver
#     immediately.
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
# iommu=pt) is per-distro (grub vs grubby) and stays in the per-flavor
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
*  soft  memlock  unlimited
*  hard  memlock  unlimited
' /etc/security/limits.d/nosi-memlock.conf 0644

nosi_info "step 23-userspace-pci done"
