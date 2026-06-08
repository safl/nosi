#!/usr/bin/env bash
# nosi/provision/steps/25-iommu-cmdline.sh
#
# Append intel_iommu=on amd_iommu=on iommu=pt to the kernel cmdline so
# vfio actually has an IOMMU to talk to once the modules from step 23
# preload. Per-distro split because the cmdline plumbing differs:
#
#   apt (debian, ubuntu): /etc/default/grub + update-grub
#   dnf (fedora):         grubby --update-kernel=ALL --args=...
#
# Takes effect on the next boot. WSL has no grub and no IOMMU; bail out
# there so apply.sh stays clean on WSL hosts.
#
# Idempotency: the apt path scans for the args before appending, so a
# re-run is a no-op. grubby is also idempotent by design.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 25-iommu-cmdline (pkgmgr=$NOSI_PKGMGR)"

if nosi_is_wsl; then
    nosi_info "WSL detected; skipping (no grub, no IOMMU)"
    exit 0
fi

# intel_iommu/amd_iommu are x86 kernel parameters, and the grub/grubby
# cmdline plumbing below does not exist on the Raspberry Pi boot path
# (kernel args live in /boot/firmware/cmdline.txt, there is no grub).
# arm64 vfio passthrough (SMMU) is out of scope for now, so skip on any
# non-x86 arch rather than half-write a config that never applies.
case "$(uname -m)" in
x86_64 | amd64) : ;;
*)
    nosi_info "non-x86 arch ($(uname -m)); skipping IOMMU cmdline (x86-only)"
    exit 0
    ;;
esac

nosi_require_root

EXTRA="intel_iommu=on amd_iommu=on iommu=pt"

case "$NOSI_PKGMGR" in
apt)
    if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        for arg in $EXTRA; do
            if ! grep -q "GRUB_CMDLINE_LINUX=.*\\b${arg}\\b" /etc/default/grub; then
                sed -i "s/^GRUB_CMDLINE_LINUX=\"\(.*\)\"$/GRUB_CMDLINE_LINUX=\"\1 ${arg}\"/" /etc/default/grub
            fi
        done
    else
        printf '\nGRUB_CMDLINE_LINUX="%s"\n' "$EXTRA" >> /etc/default/grub
    fi
    update-grub
    ;;
dnf)
    grubby --update-kernel=ALL --args="$EXTRA"
    ;;
esac

nosi_info "step 25-iommu-cmdline done"
