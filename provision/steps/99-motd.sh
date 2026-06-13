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
# proxmox is the one shape whose hostname is load-bearing (it names the PVE
# node), so its default is the shape, not the distro; step 60 bakes the
# matching /etc/hostname.
if [ -z "${NOSI_DEFAULT_HOSTNAME:-}" ] && [ "$NOSI_SHAPE" = "proxmox" ]; then
    NOSI_DEFAULT_HOSTNAME="nosi-proxmox"
fi
NOSI_DEFAULT_HOSTNAME="${NOSI_DEFAULT_HOSTNAME:-nosi-${NOSI_DISTRO}}"

nosi_info "step 99-motd (shape=$NOSI_SHAPE, default-hostname=$NOSI_DEFAULT_HOSTNAME)"
nosi_require_root

# ---- FreeBSD: static banner via /etc/motd.template ------------------------
# FreeBSD's /etc/rc.d/motd composes /etc/motd from the live uname banner +
# /etc/motd.template on each boot (update_motd=YES by default), so the
# banner goes in the TEMPLATE -- writing /etc/motd directly would be
# clobbered on the next boot. A fresh boot (the operator's, and the
# smoketest's) regenerates /etc/motd from this; composing it now is
# best-effort. The Linux dynamic renderer (IPs / IOMMU / hugepages via
# /proc + a systemd oneshot) is Linux-only; a static identity banner is
# the Phase-2a minimum.
if [ "$NOSI_DISTRO" = "freebsd" ]; then
    pretty="$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-FreeBSD}")"
    nosi_version="(unset)"
    nosi_variant="(unset)"
    if [ -r /etc/nosi-release ]; then
        # shellcheck disable=SC1091
        . /etc/nosi-release
        nosi_version="${NOSI_VERSION:-(unset)}"
        nosi_variant="${NOSI_VARIANT:-(unset)}"
    fi
    nosi_write_if_changed "
  nosi ${NOSI_SHAPE} (${nosi_variant}, ${nosi_version})   ${pretty}   $(uname -s) $(uname -r)   $(uname -m)

  Default operator: odus / odus.321  (root locked, SSH password auth on)
  Reconfigure:
    sudo passwd odus                                operator password
    sudo sysrc hostname=NAME && sudo hostname NAME  hostname (default: ${NOSI_DEFAULT_HOSTNAME})
    sudo service tailscaled enable && sudo service tailscaled start && sudo tailscale up
                                                    join tailnet (tailscale ships dormant)
" /etc/motd.template 0644
    # Compose /etc/motd now; the authoritative path is rc.d/motd on the
    # next fresh boot, so this is best-effort.
    service motd onestart >/dev/null 2>&1 || true
    nosi_info "step 99-motd done (freebsd: /etc/motd.template)"
    exit 0
fi

install -d -m 0755 /etc/nosi

nosi_write_if_changed "$NOSI_SHAPE"           /etc/nosi/shape            0644
nosi_write_if_changed "$NOSI_DEFAULT_HOSTNAME" /etc/nosi/default-hostname 0644

# ---- nosi-motd renderer ---------------------------------------------------

# The renderer below is one single-quoted string argument; its embedded awk
# programs use the '"'"' literal-single-quote idiom. shellcheck mis-tracks
# the quote state across that idiom and false-positives SC1078/SC1079 here,
# but `bash -n` confirms the quoting is balanced. Disable for this call.
# shellcheck disable=SC1078,SC1079
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
# Count controllers (/dev/nvme0, /dev/nvme1, ...), not namespaces or
# partitions: the old nvme*n* glob also matched nvme0n1p2 (the partition
# suffix still contains an n), so partitioned drives overcounted.
nvme_count="$(find /dev -maxdepth 1 -regextype posix-extended -regex ".*/nvme[0-9]+" 2>/dev/null | wc -l)"

# Default-password warning. Touched by step 29 when odus is still on the
# baked default. Operator removes it after rotating (or step 29 clears
# it on a re-run if the hash changed). Single ANSI yellow line so the
# warning stands out from the rest of the banner.
default_pw_warning=""
if [ -f /etc/nosi/default-password-active ]; then
    default_pw_warning="$(printf "\033[33m  !! odus is on the baked default password 'odus.321' -- rotate with: sudo passwd odus\033[0m\n")"
fi

# Tailscale ships installed but dormant on the bootable shapes (and is
# removed entirely from wsl / docker / lxc), so the hint renders only
# where the binary actually exists.
vpn_hint=""
if command -v tailscale >/dev/null 2>&1; then
    vpn_hint="    sudo systemctl enable --now tailscaled && sudo tailscale up   join tailnet (ships dormant)"
fi

# Proxmox hosts run headless, so the operator otherwise has to guess the web
# UI port, the login realm, and that root ships locked. Surface all of it in
# the banner, computed live so the URL tracks the current address and the
# bridge line reflects whether vmbr0 exists yet.
pve_block=""
if [ "$shape" = proxmox ]; then
    primary_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '"'"'{print $4}'"'"' | cut -d/ -f1 | head -1)"
    [ -z "$primary_ip" ] && primary_ip="<host-ip>"
    if ip -o link show type bridge 2>/dev/null | grep -q vmbr0; then
        pve_bridge="vmbr0 up"
    else
        pve_bridge="none yet; run: sudo nosi-proxmox-mkbridge && sudo ifreload -a"
    fi
    pve_block="
  Proxmox VE:
    web UI:  https://${primary_ip}:8006
    login:   first set a root password: sudo passwd root
             then log in as root, realm: Linux PAM standard authentication
             (odus, same realm, is also an admin)
    bridge:  ${pve_bridge}
    storage: a blank extra disk auto-enrolls as nvme-data; else Datacenter > Storage
"
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
${pve_block}
  Tools:     rg fd fzf lazygit delta yazi oras gh just direnv
  Helpers:
    iommu {show|off-for-uio|off-for-vfio|strict|pt}   IOMMU substrate (reboot to apply)
    devbind                                           bind/unbind PCI device to a driver
    hugepages                                         inspect / reserve hugepages
    nosi-selfcheck                                     verify the box matches a healthy nosi image
  Reconfigure:
    sudo systemd-firstboot --force --prompt           interactive locale/keymap/timezone/hostname
    sudo timedatectl set-timezone Europe/Copenhagen   timezone (default: UTC)
    sudo hostnamectl set-hostname NAME                hostname (default: ${default_host})
    sudo passwd odus                                  operator password (default: odus.321)
${vpn_hint}
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
