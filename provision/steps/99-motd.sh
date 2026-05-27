#!/usr/bin/env bash
# nosi/provision/steps/99-motd.sh
#
# Runs LAST in apply.sh. Generates /etc/motd from a per-boot snapshot:
# build identity / distro / kernel / IPs / IOMMU mode / hugepages / CPU /
# RAM / NVMe count / helper hints. A systemd oneshot runs the renderer at
# boot so IP and IOMMU columns are always current at login time.
#
# Numbered 99 deliberately: a flashed nosi image that shows the banner at
# login means every earlier provision step succeeded. A bare login prompt
# with no banner is the at-a-glance signal that something broke before
# the end of apply.sh; /etc/nosi-release (written first, by step 05) then
# tells the operator which build to look at.
#
# The renderer is identical across all nosi shapes. The two pieces of
# variant state (shape name in the banner, default-hostname in the
# Reconfigure hint) are read at render time from /etc/nosi/ config
# files written by this step, so adding a new shape is purely config,
# not a script edit.
#
# Inputs (env vars, optional):
#   NOSI_SHAPE              "headless" (default), "desktop", "wsl".
#                           Surfaces in the banner header.
#   NOSI_DEFAULT_HOSTNAME   Hostname nosi shipped with. Surfaces in the
#                           Reconfigure hint. Defaults to
#                           nosi-${NOSI_DISTRO}.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

NOSI_SHAPE="${NOSI_SHAPE:-headless}"
NOSI_DEFAULT_HOSTNAME="${NOSI_DEFAULT_HOSTNAME:-nosi-${NOSI_DISTRO}}"

nosi_info "step 99-motd (shape=$NOSI_SHAPE, default-hostname=$NOSI_DEFAULT_HOSTNAME)"
nosi_require_root

install -d -m 0755 /etc/nosi

nosi_write_if_changed "$NOSI_SHAPE"           /etc/nosi/shape            0644
nosi_write_if_changed "$NOSI_DEFAULT_HOSTNAME" /etc/nosi/default-hostname 0644

# ---- nosi-motd renderer ---------------------------------------------------

nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/99-motd.sh
# /usr/local/bin/nosi-motd: print the nosi login banner to stdout.
# Wrapped by nosi-motd.service at boot into /etc/motd.
set -eu

. /etc/os-release 2>/dev/null || true
distro="${PRETTY_NAME:-Linux}"
kernel="$(uname -r)"
arch="$(uname -m)"
host="$(hostnamectl --static 2>/dev/null || hostname)"

shape="$(cat /etc/nosi/shape 2>/dev/null || echo headless)"
default_host="$(cat /etc/nosi/default-hostname 2>/dev/null || echo nosi-${ID:-linux})"

# Build identity from /etc/nosi-release (written first by step 05). Falls
# back to "(unset)" so the banner still renders on a system where step 05
# has not run yet (e.g. mid-bake partial state).
nosi_variant="(unset)"
nosi_version="(unset)"
if [ -r /etc/nosi-release ]; then
    v="$(awk -F= '"'"'$1=="NOSI_VARIANT" {print $2; exit}'"'"' /etc/nosi-release)"
    [ -n "$v" ] && nosi_variant="$v"
    v="$(awk -F= '"'"'$1=="NOSI_VERSION" {print $2; exit}'"'"' /etc/nosi-release)"
    [ -n "$v" ] && nosi_version="$v"
fi

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

# Default-password warning. Touched by step 29 when odus is still on the
# baked default. Operator removes it after rotating (or step 29 clears
# it on a re-run if the hash changed). Single ANSI yellow line so the
# warning stands out from the rest of the banner.
default_pw_warning=""
if [ -f /etc/nosi/default-password-active ]; then
    default_pw_warning="$(printf "\033[33m  !! odus is on the baked default password 'odus.321' -- rotate with: sudo passwd odus\033[0m\n")"
fi

cat <<EOM

  nosi ${shape} (${nosi_variant}, ${nosi_version})   ${distro}   Linux ${kernel}   ${arch}
${default_pw_warning}

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

nosi_info "step 99-motd done"
