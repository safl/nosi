#!/usr/bin/env bash
# nosi/provision/steps/32-firstboot-inventory.sh
#
# Forensic snapshot of system state, captured exactly once to
# /var/log/nosi-firstboot.txt. Useful to diff against later state when
# something broke and you want to know what changed since flash:
# kernel, /proc/cmdline, NIC presence/IPs, lsblk, lspci, nvme list,
# IOMMU mode + group layout, devbind state, hugepages, RAM, CPU,
# prlimit (memlock matters for DPDK/SPDK and xNVMe/uPCIe via vfio-pci).
#
# The systemd unit has ConditionPathExists=!/var/log/nosi-firstboot.txt
# so it short-circuits on every boot after the first. Cross-distro,
# pure file writes + systemctl enable; safe to re-run.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 32-firstboot-inventory (distro=$NOSI_DISTRO)"
nosi_require_root

nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/32-firstboot-inventory.sh
set -eu
out=/var/log/nosi-firstboot.txt
{
    echo "# nosi-firstboot-inventory $(date -Iseconds)"
    echo
    echo "## /etc/os-release"
    cat /etc/os-release 2>/dev/null || true
    echo
    echo "## uname -a"
    uname -a
    echo
    echo "## /proc/cmdline"
    cat /proc/cmdline
    echo
    echo "## ip -br a"
    ip -br a 2>/dev/null || true
    echo
    echo "## lsblk"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || true
    echo
    echo "## lspci -nn"
    lspci -nn 2>/dev/null || true
    echo
    echo "## nvme list"
    nvme list 2>/dev/null || true
    echo
    echo "## iommu show"
    iommu show 2>/dev/null || true
    echo
    echo "## devbind --list"
    devbind --list 2>/dev/null || true
    echo
    echo "## hugepages info"
    hugepages info 2>/dev/null || true
    echo
    echo "## free -h"
    free -h
    echo
    echo "## prlimit (memlock matters for DPDK/SPDK and xNVMe/uPCIe via vfio-pci)"
    prlimit 2>/dev/null || true
    echo
    echo "## CPU (first block of /proc/cpuinfo)"
    awk '"'"'/^$/ {exit} 1'"'"' /proc/cpuinfo
} > "$out"
' /usr/local/bin/nosi-firstboot-inventory 0755

nosi_write_if_changed \
'[Unit]
Description=Capture first-boot inventory to /var/log/nosi-firstboot.txt
After=network-online.target nosi-motd.service
Wants=network-online.target
ConditionPathExists=!/var/log/nosi-firstboot.txt

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nosi-firstboot-inventory
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
' /etc/systemd/system/nosi-firstboot-inventory.service 0644

systemctl daemon-reload
systemctl enable nosi-firstboot-inventory.service

nosi_info "step 32-firstboot-inventory done"
