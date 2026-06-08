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

# ---- 4. modprobe.d softdep -----------------------------------------------
# Targeted preference, NOT a blanket r8169 blacklist. See the comment at
# the top of this script for rationale.

nosi_write_if_changed \
"# Managed by nosi/provision/steps/10-r8125-dkms.sh
# Prefer r8125 over r8169 for RTL8125 chips ONLY. r8169 still serves
# RTL8111 (1GbE) + the rest of the Realtek family on the same machine.
softdep r8169 pre: r8125
" /etc/modprobe.d/nosi-r8125.conf 0644

nosi_info "step 10-r8125-dkms done"
