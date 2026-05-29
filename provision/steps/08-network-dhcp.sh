#!/usr/bin/env bash
# nosi/provision/steps/08-network-dhcp.sh
#
# Deterministic, NIC-agnostic networking, valid whether or not cloud-init
# runs on the target.
#
# Why this exists: nosi images are flashed to bare metal with NO
# cloud-init datasource. cloud-init runs exactly once -- inside the QEMU
# build VM -- where it renders /etc/netplan/50-cloud-init.yaml pinned to
# the BUILD VM's NIC (match: macaddress and/or set-name). The end-of-bake
# `cloud-init clean --logs --seed` does NOT remove that file (plain clean
# keeps generated netplan; only `clean --configs network` would), so the
# build VM's netplan ships verbatim. On the target box cloud-init finds
# no datasource and self-disables for the boot (`cloud-init status` =>
# disabled), so it never re-renders networking -- the stale, build-VM
# netplan is the ONLY network config present, and the real NIC (different
# MAC/name) never comes up. Observed: ubuntu-2404-headless dead on HW
# while ubuntu-2604-headless lived on the same box, purely by which pin
# each build happened to bake.
#
# Fix: own networking ourselves with ONE NIC-agnostic policy expressed in
# two places that carry the identical glob, so it holds in both worlds:
#
#   * /etc/cloud/cloud.cfg.d/90-nosi-network.cfg -- for every host where
#     cloud-init DOES run (VMs/cloud). cloud-init renders a correct,
#     glob-matched netplan from it; if that rendered file later lingers,
#     it is still useful (matched by NAME, not a dead MAC). As cloud-init
#     "system config", it sits BELOW datasource network-config in
#     priority, so a real cloud that pushes a static address still wins.
#   * /etc/netplan/50-nosi.yaml -- the concrete config for the
#     datasource-less bare-metal boot, where cloud-init is disabled and
#     the drop-in above never gets rendered. Same nosi-en/nosi-eth ids as
#     the drop-in, so when cloud-init DOES render its own file the two
#     deep-merge cleanly (identical definitions, no duplicate-iface race).
#
# Either way: DHCP on any wired interface matched by NAME GLOB (en*
# predictable + eth* legacy/VM, never by MAC), so the same image works on
# whatever NIC the target box happens to have. We also delete the
# build-VM 50-cloud-init.yaml so its dead pin cannot win on HW. Fedora
# cloud images render via NetworkManager, whose default already DHCPs any
# ethernet, so there the drop-in (for the cloud-init case) plus clearing
# the baked keyfile is the whole fix.
#
# We write config but never `netplan apply`: the build VM keeps its live
# (cloud-init-brought-up) link through the rest of the bake; the new
# config takes effect on the next boot -- first boot on the real box, and
# the smoketest's fresh boot, which validates it.
#
# Idempotent: nosi_write_if_changed rewrites only on content change;
# rm -f no-ops when the file is already absent.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 08-network-dhcp (distro=$NOSI_DISTRO)"

if nosi_is_wsl; then
    nosi_info "WSL detected; networking is managed by the WSL host, skipping"
    exit 0
fi

nosi_require_root

# ---- 1. cloud-init drop-in: glob DHCP for hosts where cloud-init runs -----
# Applies on every distro. Renders a NIC-agnostic netplan (or NM keyfiles
# on Fedora) on VMs/cloud; harmless on HW where cloud-init is disabled.
nosi_write_if_changed \
"# Managed by nosi/provision/steps/08-network-dhcp.sh
# DHCP on any wired interface, matched by NAME (en* predictable + eth*
# legacy/VM), never by MAC. Mirrors /etc/netplan/50-nosi.yaml so the two
# agree when cloud-init renders this. Below datasource network-config in
# priority, so a cloud pushing a static address still wins.
network:
  version: 2
  ethernets:
    nosi-en:
      match: {name: \"en*\"}
      dhcp4: true
      dhcp6: true
      optional: true
    nosi-eth:
      match: {name: \"eth*\"}
      dhcp4: true
      dhcp6: true
      optional: true
" /etc/cloud/cloud.cfg.d/90-nosi-network.cfg 0644

# ---- 2. concrete netplan for the datasource-less bare-metal boot ----------
case "$NOSI_PKGMGR" in
apt)
    # Same glob + same ids as the cloud-init drop-in above.
    nosi_write_if_changed \
"# Managed by nosi/provision/steps/08-network-dhcp.sh
# DHCP on any wired interface, matched by NAME (en* predictable + eth*
# legacy/VM), never by MAC. optional:true keeps boot from blocking on a
# NIC with no carrier. Mirrors /etc/cloud/cloud.cfg.d/90-nosi-network.cfg.
network:
  version: 2
  renderer: networkd
  ethernets:
    nosi-en:
      match: {name: \"en*\"}
      dhcp4: true
      dhcp6: true
      optional: true
    nosi-eth:
      match: {name: \"eth*\"}
      dhcp4: true
      dhcp6: true
      optional: true
" /etc/netplan/50-nosi.yaml 0600

    # Drop the build-VM artifact pinned to the QEMU NIC. Our config
    # supersedes it; leaving it would let a dead MAC pin win on HW.
    rm -f /etc/netplan/50-cloud-init.yaml

    # Validate the YAML we just wrote (generate backends only, no apply --
    # the live link stays up for the rest of the bake). Fail loud on a typo.
    if command -v netplan >/dev/null 2>&1; then
        netplan generate || nosi_die "netplan generate rejected /etc/netplan/50-nosi.yaml"
    fi
    ;;
dnf)
    # Fedora cloud images use NetworkManager; its default connection
    # auto-DHCPs any ethernet, so the cloud-init drop-in (for the VM case)
    # plus clearing the build-VM keyfile is the whole fix on HW.
    rm -f /etc/NetworkManager/system-connections/cloud-init-*.nmconnection
    ;;
esac

nosi_info "step 08-network-dhcp done"
