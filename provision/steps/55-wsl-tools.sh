#!/usr/bin/env bash
# nosi/provision/steps/55-wsl-tools.sh
#
# wsl shape only. Adds the GUI dev tools that render through WSLg
# (meld / gitk / git-gui) without a compositor inside the rootfs, plus
# xdg-utils so xdg-open hands URLs to the Windows-side browser through
# WSLg's interop layer.
#
# Installed HERE rather than in cloud-init so `apply.sh <distro>-wsl`
# fully defines the wsl shape: the derive-from-headless build runs this
# one step on the baked headless rootfs (then strips kernel/boot/
# cloud-init in derive_publish), and a vanilla-VM operator reaches the
# same result. Ubuntu (apt) is the only wsl distro today; names are apt.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 55-wsl-tools (shape=${NOSI_SHAPE:-?})"

if [ "${NOSI_SHAPE:-}" != "wsl" ]; then
    nosi_info "non-wsl shape; skipping"
    exit 0
fi

nosi_require_root

if [ "${NOSI_PKGMGR:-}" != "apt" ]; then
    nosi_die "wsl shape currently supports Ubuntu/Debian (apt) only; got pkgmgr=${NOSI_PKGMGR:-?}"
fi
nosi_pkg_install meld gitk git-gui xdg-utils

nosi_info "step 55-wsl-tools done"
