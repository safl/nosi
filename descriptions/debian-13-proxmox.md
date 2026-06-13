Debian 13 (trixie) as a Proxmox VE host (PVE 9, no-subscription) on top of
the headless baseline, so the hypervisor inherits nosi's hardware support +
IOMMU/vfio tuning and the dev toolset on the host. Flash to the OS NVMe; PVE
daemons come up on first boot (web UI on :8006).
