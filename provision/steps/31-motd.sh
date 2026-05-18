#!/usr/bin/env bash
# nosi/provision/steps/31-motd.sh
#
# Generate /etc/motd from a per-boot snapshot: distro / kernel / IPs /
# IOMMU mode / hugepages / CPU / RAM / NVMe count / helper hints. A
# systemd oneshot runs the renderer at boot so the IP and IOMMU columns
# are always current at login time.
#
# The renderer is identical across all four nosi flavors. The two
# pieces of variant state (flavor name in the banner, default-hostname
# in the Reconfigure hint) are read at render time from /etc/nosi/
# config files written by this step, so adding a new flavor is purely
# config, not a script edit.
#
# Inputs (env vars, optional):
#   NOSI_FLAVOR             "sysdev" (default) or "aidev". Surfaces in
#                           the banner header.
#   NOSI_DEFAULT_HOSTNAME   Hostname nosi shipped with. Surfaces in the
#                           Reconfigure hint. Default derives from
#                           NOSI_DISTRO + NOSI_FLAVOR (see below).

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

NOSI_FLAVOR="${NOSI_FLAVOR:-sysdev}"
if [ -z "${NOSI_DEFAULT_HOSTNAME:-}" ]; then
    if [ "$NOSI_FLAVOR" = "aidev" ]; then
        NOSI_DEFAULT_HOSTNAME="nosi-aidev"
    else
        NOSI_DEFAULT_HOSTNAME="nosi-${NOSI_DISTRO}"
    fi
fi

nosi_info "step 31-motd (flavor=$NOSI_FLAVOR, default-hostname=$NOSI_DEFAULT_HOSTNAME)"
nosi_require_root

install -d -m 0755 /etc/nosi

nosi_write_if_changed "$NOSI_FLAVOR"           /etc/nosi/flavor           0644
nosi_write_if_changed "$NOSI_DEFAULT_HOSTNAME" /etc/nosi/default-hostname 0644

# ---- nosi-motd renderer ---------------------------------------------------

nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/31-motd.sh
# /usr/local/bin/nosi-motd: print the nosi login banner to stdout.
# Wrapped by nosi-motd.service at boot into /etc/motd.
set -eu

. /etc/os-release 2>/dev/null || true
distro="${PRETTY_NAME:-Linux}"
kernel="$(uname -r)"
arch="$(uname -m)"
host="$(hostnamectl --static 2>/dev/null || hostname)"

flavor="$(cat /etc/nosi/flavor 2>/dev/null || echo sysdev)"
default_host="$(cat /etc/nosi/default-hostname 2>/dev/null || echo nosi-${ID:-linux})"

ips=""
while IFS= read -r line; do
    iface="$(echo "$line" | awk '"'"'{print $2}'"'"')"
    addr="$(echo "$line" | awk '"'"'{print $4}'"'"' | cut -d/ -f1)"
    [ -z "$addr" ] && continue
    ips="${ips}${ips:+, }${addr} (${iface})"
done <<EOF
$(ip -4 -o addr show scope global 2>/dev/null)
EOF
[ -z "$ips" ] && ips="(none)"

iommu="$(iommu show 2>/dev/null | awk '"'"'/^mode:/ {print $2}'"'"')"
[ -z "$iommu" ] && iommu="unset"

hp_count="$(awk '"'"'/HugePages_Total:/ {print $2}'"'"' /proc/meminfo)"
hp_size_kb="$(awk '"'"'/Hugepagesize:/ {print $2}'"'"' /proc/meminfo)"
if [ "${hp_count:-0}" -gt 0 ]; then
    hp_mib=$(( hp_count * hp_size_kb / 1024 ))
    hugepgs="${hp_count} x ${hp_size_kb} kB = ${hp_mib} MiB"
else
    hugepgs="0 (use '"'"'hugepages'"'"' to allocate)"
fi

cpu_model="$(awk -F'"'"': '"'"' '"'"'/^model name/ {print $2; exit}'"'"' /proc/cpuinfo)"
cpu_count="$(nproc)"
ram_kib="$(awk '"'"'/MemTotal:/ {print $2}'"'"' /proc/meminfo)"
ram_gib=$(( ram_kib / 1024 / 1024 ))
nvme_count="$(find /dev -maxdepth 1 -name '"'"'nvme*n*'"'"' 2>/dev/null | wc -l)"

cat <<EOM

  nosi ${flavor}   ${distro}   Linux ${kernel}   ${arch}

  hostname:  ${host}
  ip:        ${ips}
  iommu:     ${iommu}
  hugepgs:   ${hugepgs}
  cpu:       ${cpu_model} x ${cpu_count}
  ram:       ${ram_gib} GiB
  nvme:      ${nvme_count}

  Tools:     rg fd fzf lazygit delta yazi oras gh just direnv
  Helpers:
    iommu {show|off-for-uio|off-for-vfio|strict|pt}   IOMMU substrate (reboot to apply)
    devbind                                           bind/unbind PCI device to a driver
    hugepages                                         inspect / reserve hugepages
  Reconfigure:
    sudo systemd-firstboot --force --prompt           interactive locale/keymap/timezone/hostname
    sudo timedatectl set-timezone Europe/Copenhagen   timezone (default: UTC)
    sudo hostnamectl set-hostname NAME                hostname (default: ${default_host})
    sudo passwd odus                                  operator password (default: odus.321)

EOM
' /usr/local/bin/nosi-motd 0755

# ---- nosi-motd.service: render at boot ------------------------------------

nosi_write_if_changed \
"[Unit]
Description=Generate nosi banner for /etc/motd
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/local/bin/nosi-motd > /etc/motd'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
" /etc/systemd/system/nosi-motd.service 0644

systemctl daemon-reload
systemctl enable nosi-motd.service

nosi_info "step 31-motd done"
