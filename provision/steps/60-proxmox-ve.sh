#!/usr/bin/env bash
# nosi/provision/steps/60-proxmox-ve.sh
#
# proxmox shape only. Turns the headless Debian base into a Proxmox VE host
# (PVE 9 on Debian 13 trixie, no-subscription repo).
#
# This runs in the derive chroot (derive_pack copies the baked headless rootfs
# and chroots in). proxmox-ve's postinst scripts try to START daemons
# (pve-cluster/pmxcfs, pvedaemon, ...), which cannot run under a chroot with no
# PID 1. The standard chroot technique handles that: a policy-rc.d returning
# 101 makes invoke-rc.d skip every service start during the install, and the
# daemons come up normally on the first real boot. So the bake installs +
# configures Proxmox; first boot brings it to life (pveproxy on :8006).
#
# Networking (vmbr0 bridge) and the second-NVMe storage are deliberately NOT
# set up here -- those need the live system and the operator's hardware, and
# are handled by a first-boot helper / documented setup. The host is fully
# usable without them (add the bridge + storage from the web UI or the helper).

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 60-proxmox-ve (shape=${NOSI_SHAPE:-?})"

if [ "${NOSI_SHAPE:-}" != "proxmox" ]; then
    nosi_info "non-proxmox shape; skipping"
    exit 0
fi

nosi_require_root

if [ "${NOSI_PKGMGR:-}" != "apt" ]; then
    nosi_die "proxmox shape is Debian-only (PVE on trixie); got pkgmgr=${NOSI_PKGMGR:-?}"
fi

export DEBIAN_FRONTEND=noninteractive

# Deny service starts for the duration of the install (chroot has no PID 1).
cat >/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 /usr/sbin/policy-rc.d

# PVE 9 no-subscription repo (Debian 13 trixie) + release key. signed-by keeps
# the key scoped to this repo rather than trusting it system-wide.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
    -o /etc/apt/keyrings/proxmox-release-trixie.gpg
cat >/etc/apt/sources.list.d/pve.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

# postfix is pulled in by proxmox-ve; preseed it as a local-only MTA so the
# install never blocks on a debconf prompt.
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string nosi-proxmox" | debconf-set-selections

apt-get update
apt-get install -y proxmox-ve postfix open-iscsi chrony

# Proxmox ships + boots its own kernel; drop the Debian cloud kernel and
# os-prober so GRUB defaults to the PVE kernel (per Proxmox's install-on-Debian
# guide). proxmox-ve already pulled proxmox-default-kernel, so a kernel remains.
apt-get remove -y os-prober 'linux-image-amd64' 'linux-image-6.*' 2>/dev/null || true
update-grub 2>/dev/null || true

# ---- first-boot: make the node hostname resolvable (pmxcfs needs it) -------
# pve-cluster (pmxcfs) refuses to start unless the node hostname resolves to an
# address, and everything else (pvedaemon, pveproxy, pvestatd, pve-firewall)
# Requires it. Cloud images ship /etc/hosts without a hostname entry and rely on
# cloud-init to add one -- but cloud-init is disabled on a flashed host, so add
# it ourselves, ordered Before=pve-cluster. Read the live hostname each boot so
# it works whatever the host ends up named (static or DHCP-assigned).
nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/60-proxmox-ve.sh
set -u
hn=$(hostname 2>/dev/null)
[ -n "$hn" ] && [ "$hn" != "localhost" ] || exit 0
# Already resolvable (an /etc/hosts entry or DNS) -> nothing to do.
getent hosts "$hn" >/dev/null 2>&1 && exit 0
printf "127.0.1.1\t%s.localdomain %s\n" "$hn" "$hn" >> /etc/hosts
' /usr/local/sbin/nosi-proxmox-hosts 0755

nosi_write_if_changed \
'[Unit]
Description=nosi: ensure the node hostname resolves (required by pmxcfs)
DefaultDependencies=no
After=local-fs.target
Before=pve-cluster.service basic.target
ConditionPathExists=/usr/bin/pmxcfs

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nosi-proxmox-hosts
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
' /etc/systemd/system/nosi-proxmox-hosts.service 0644
systemctl enable nosi-proxmox-hosts.service 2>/dev/null || true

# ---- first-boot: directory storage on a blank second disk -----------------
# The operator runs the OS on one NVMe and wants VM/CT storage on a second.
# This oneshot sets that up automatically, but only for a disk that is
# DEFINITELY safe: a whole disk that is not the boot disk, has no partitions,
# and has no filesystem/partition-table signature (wipefs -n is empty). It
# never touches a disk with data, and no-ops once `nvme-data` exists.
nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/60-proxmox-ve.sh
set -u
log(){ logger -t nosi-proxmox-storage "$*" 2>/dev/null; echo "nosi-proxmox-storage: $*"; }
command -v pvesm >/dev/null 2>&1 || exit 0
pvesm status 2>/dev/null | grep -q "^nvme-data" && exit 0
root_src=$(findmnt -nvo SOURCE / 2>/dev/null)
root_disk=$(lsblk -ndo PKNAME "$root_src" 2>/dev/null)
cand=""
for d in $(lsblk -dno NAME); do
    [ "$(lsblk -dno TYPE /dev/$d 2>/dev/null)" = "disk" ] || continue
    [ "$d" = "$root_disk" ] && continue
    [ -n "$(lsblk -no NAME /dev/$d | tail -n +2)" ] && continue
    [ -n "$(wipefs -n /dev/$d 2>/dev/null)" ] && continue
    cand="$cand $d"
done
set -- $cand
[ "$#" -eq 1 ] || { log "need exactly one blank non-boot disk, found: $* ; skipping"; exit 0; }
disk=/dev/$1
log "formatting $disk as ext4 directory storage"
mkfs.ext4 -q -F -L nosi-vmstore "$disk" || { log "mkfs failed"; exit 0; }
mkdir -p /var/lib/nosi-vmstore
uuid=$(blkid -s UUID -o value "$disk")
grep -q "$uuid" /etc/fstab 2>/dev/null || printf "UUID=%s /var/lib/nosi-vmstore ext4 defaults,nofail 0 2\n" "$uuid" >> /etc/fstab
mount /var/lib/nosi-vmstore 2>/dev/null || true
pvesm add dir nvme-data --path /var/lib/nosi-vmstore --content images,rootdir,iso,vztmpl,backup,snippets || log "pvesm add failed"
log "done: nvme-data on $disk at /var/lib/nosi-vmstore"
' /usr/local/sbin/nosi-proxmox-storage 0755

nosi_write_if_changed \
'[Unit]
Description=nosi: set up a blank second disk as Proxmox directory storage
After=pve-cluster.service pveproxy.service
Wants=pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nosi-proxmox-storage
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
' /etc/systemd/system/nosi-proxmox-storage.service 0644
systemctl enable nosi-proxmox-storage.service 2>/dev/null || true

# ---- helper (manual): create the vmbr0 bridge ------------------------------
# Not run automatically: rewriting /etc/network/interfaces + handing the NIC
# from the base networking to ifupdown2 is best done where it can be verified
# (the web UI does it well). This writes the config + a backup and tells the
# operator to apply it; `ifreload -a` activates it.
nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/60-proxmox-ve.sh -- create vmbr0 over the
# primary NIC (DHCP). Review, then apply with: ifreload -a
set -u
log(){ echo "nosi-proxmox-mkbridge: $*"; }
ip -o link show type bridge 2>/dev/null | grep -q vmbr0 && { log "vmbr0 already exists"; exit 0; }
nic=$(ip -o route show default 2>/dev/null | sed -n "s/.* dev \([^ ]*\).*/\1/p" | head -1)
[ -n "$nic" ] || { log "no default-route NIC found; aborting"; exit 1; }
cp /etc/network/interfaces /etc/network/interfaces.nosi-bak 2>/dev/null || true
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

iface $nic inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports $nic
    bridge-stp off
    bridge-fd 0
EOF
log "wrote vmbr0 over $nic (backup: /etc/network/interfaces.nosi-bak)"
log "apply with: ifreload -a"
' /usr/local/sbin/nosi-proxmox-mkbridge 0755

# Restore normal service-start behavior for the first real boot.
rm -f /usr/sbin/policy-rc.d
apt-get clean

nosi_info "step 60-proxmox-ve done (PVE installed; daemons + storage on first boot)"
