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

# Restore normal service-start behavior for the first real boot.
rm -f /usr/sbin/policy-rc.d
apt-get clean

nosi_info "step 60-proxmox-ve done (PVE installed; daemons start on first boot)"
