#!/usr/bin/env bash
# nosi/provision/steps/10-r8125-dkms.sh
#
# Install Realtek r8125 out-of-tree driver via DKMS, with a targeted
# softdep so r8125 wins for RTL8125 PCI IDs but r8169 keeps serving every
# other Realtek chip (RTL8111 1GbE, etc.) on the same machine.
#
# Background: mainline r8169 covers RTL8125 on the kernels we ship, but
# specific 2.5GbE boards (notably the dual-2.5GbE NICs on the GMKtec
# NucBox G10 / Ryzen 5) hit link-flap under load on r8169 that Realtek's
# own r8125 driver does not. Realtek's upstream tarball ships a blanket
# `blacklist r8169` modprobe.d entry; we deliberately do NOT use it
# because it would break 1GbE on systems whose only Realtek NIC is an
# RTL8111. The softdep keeps r8169 available, just lower priority for
# the chips r8125 explicitly claims. On a box with no RTL8125 at all,
# r8125 stays built-but-unloaded (no PCI alias match, softdep no-op).
#
# The driver alone is not enough on these mini-PCs; this step ports the
# three further RTL8125 mitigations bty (the netboot image) needs just to
# PXE-boot the same boards:
#   * firmware: the rtl_nic/*.fw blobs the driver loads ship in
#     firmware-realtek on Debian (firmware-misc-nonfree does NOT carry NIC
#     firmware), so debian-13's package list installs it; Ubuntu/Fedora get
#     it from their monolithic linux-firmware. Without it the NIC probe can
#     fail outright and the link never comes up -> no DHCP, no IP.
#   * ASPM + EEE: on the GMKtec G5/G10 dual-2.5GbE boards PCIe ASPM L1
#     transitions drop packets mid-transfer and Energy-Efficient Ethernet
#     flaps the link, so we pass `options r8125 enable_eee=0 aspm=0`.
#   * TX/RX offloads: some RTL8125/8126 firmware advertises TSO/GSO/GRO/LRO
#     and TX-checksum offload but emits malformed frames peers silently
#     drop, so DHCP and ping work while any real TCP transfer stalls. A udev
#     rule turns the offloads off at link-up for whichever driver (r8125 or
#     the r8169 fallback) bound the NIC.
#
# Cross-distro: works on apt (debian, ubuntu) + dnf (fedora). WSL exits
# early because there are no kernel headers for the WSL kernel.
#
# Idempotency: re-running is safe. If DKMS already has the latest
# upstream tag installed and the modprobe.d softdep is in place, the
# step no-ops apart from a couple of curl HEADs.
#
# Source: github.com/awesometic/realtek-r8125-dkms (Realtek upstream
# repackaged for DKMS, releases keep pace with Realtek tarball drops).

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 10-r8125-dkms (distro=$NOSI_DISTRO, pkgmgr=$NOSI_PKGMGR)"

if nosi_is_wsl; then
    nosi_info "WSL detected; skipping (no real kernel, no DKMS targets)"
    exit 0
fi

# The RTL8125 2.5GbE part this driver targets is an x86 add-in/onboard NIC;
# arm64 boards (e.g. Raspberry Pi 4/5) drive their on-board NICs from
# in-tree modules in their own kernel and never carry an RTL8125. DKMS also
# cannot build here in an arm64 chroot bake (no matching running kernel /
# headers). Skip on any non-x86 arch -- same `uname -m` idiom as step 20.
case "$(uname -m)" in
x86_64 | amd64) : ;;
*)
    nosi_info "non-x86 arch ($(uname -m)); skipping r8125 (x86-only NIC)"
    exit 0
    ;;
esac

nosi_require_root

# ---- 1. install DKMS + kernel headers/devel matching the running kernel ---
# Also pull headers for any installed kernel image metapackage so DKMS
# autoinstall handles the package_upgrade-bumped-kernel case (running
# kernel older than the one apt/dnf just laid down).

case "$NOSI_PKGMGR" in
apt)
    nosi_pkg_install dkms "linux-headers-$(uname -r)" || true
    for img_meta in linux-image-amd64 linux-image-cloud-amd64 \
                    linux-image-virtual linux-image-generic; do
        if nosi_pkg_installed "$img_meta"; then
            hdr_meta="${img_meta/linux-image-/linux-headers-}"
            nosi_pkg_install "$hdr_meta" || true
            break
        fi
    done
    ;;
dnf)
    # `kernel-devel` (unversioned) tracks the latest installed kernel;
    # plus the running kernel's matching package in case package_upgrade
    # staged a newer kernel that hasn't booted yet.
    nosi_pkg_install dkms "kernel-devel-$(uname -r)" kernel-devel
    ;;
esac

# ethtool backs the offload-disable udev rule written in section 5 (and is
# a handy NIC diagnostic: `ethtool -i`/`-k`/`-S`). Same package name on apt
# + dnf. Not a list package so apply.sh keeps parity on a vanilla VM too.
# It is an sbin admin tool (/usr/sbin/ethtool); the udev rule invokes it by
# absolute path, so it need not be on any unprivileged user's PATH (Debian
# keeps sbin off a non-root PATH, unlike Ubuntu/Fedora).
nosi_pkg_install ethtool || true

# ---- 2. resolve the latest upstream release tag --------------------------

ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/awesometic/realtek-r8125-dkms/releases/latest \
    | sed 's#.*/tag/##' | sed 's/^v//')
[ -n "$ver" ] || nosi_die "could not resolve latest realtek-r8125-dkms tag"

nosi_info "latest upstream tag: $ver"

# ---- 3. skip the fetch+dkms-add if this version is already installed -----

if dkms status r8125 2>/dev/null | grep -q "^r8125, *${ver}"; then
    nosi_info "r8125 ${ver} already in dkms; skipping build"
else
    if [ ! -d "/usr/src/r8125-${ver}" ]; then
        nosi_info "fetching r8125 ${ver} source"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        curl -fsSL "https://github.com/awesometic/realtek-r8125-dkms/archive/refs/tags/${ver}.tar.gz" \
            | tar -xz -C "$tmp"
        src=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)
        install -d "/usr/src/r8125-${ver}"
        cp -a "$src/." "/usr/src/r8125-${ver}/"
    fi
    dkms add -m r8125 -v "${ver}" || true   # already-added is fine
    dkms autoinstall
fi

# ---- 4. modprobe.d: softdep + ASPM/EEE options ---------------------------
# Targeted preference, NOT a blanket r8169 blacklist. See the comment at
# the top of this script for rationale. The options line is a no-op when
# r8125 is not the bound driver (e.g. r8169 fallback, or no RTL8125 at all),
# so it is safe to ship unconditionally.

nosi_write_if_changed \
"# Managed by nosi/provision/steps/10-r8125-dkms.sh
# Prefer r8125 over r8169 for RTL8125 chips ONLY. r8169 still serves
# RTL8111 (1GbE) + the rest of the Realtek family on the same machine.
softdep r8169 pre: r8125
# Disable PCIe ASPM and Energy-Efficient Ethernet: on the GMKtec G5/G10
# dual-2.5GbE boards ASPM L1 transitions drop packets mid-transfer and EEE
# flaps the link. Harmless when r8125 is not the loaded driver.
options r8125 enable_eee=0 aspm=0
" /etc/modprobe.d/nosi-r8125.conf 0644

# ---- 5. udev: disable suspect Realtek 2.5GbE offloads at link-up ---------
# RTL8125/8125B/8126 firmware advertises TSO/GSO/GRO/LRO + TX checksum
# offload but, on some revisions, emits malformed frames that peers (apt
# mirrors, OCI registries) drop silently. Net effect: DHCP and ping work
# (small packets) while any larger TCP transfer stalls. Force software
# segmentation/checksum via ethtool when the NIC appears. Fires for both
# r8125 (the DKMS driver above) and r8169 (the in-tree fallback) since a
# kernel update or override could put either in play. ATTR{type}=="1"
# limits it to ethernet, skipping the tap/bridge devices NetworkManager
# creates later. /sbin/ethtool resolves via usr-merge on all three distros.
nosi_write_if_changed \
'# Managed by nosi/provision/steps/10-r8125-dkms.sh
ACTION=="add", SUBSYSTEM=="net", ATTR{type}=="1", DRIVERS=="r8125", RUN+="/sbin/ethtool -K $env{INTERFACE} tso off gso off gro off lro off tx-checksum-ip-generic off"
ACTION=="add", SUBSYSTEM=="net", ATTR{type}=="1", DRIVERS=="r8169", RUN+="/sbin/ethtool -K $env{INTERFACE} tso off gso off gro off lro off tx-checksum-ip-generic off"
' /etc/udev/rules.d/70-nosi-realtek-2g5-offloads.rules 0644

nosi_info "step 10-r8125-dkms done"
