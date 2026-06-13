#!/usr/bin/env bash
# nosi/provision/steps/06-package-presence.sh
#
# Pre-flight: verify cloud-init's packages: install actually populated
# the baseline tools. dnf5 (Fedora) aborts the whole transaction on a
# single missing package name, so a typo / rename in the variant's
# userdata cascades to every package being skipped -- and the symptom
# downstream is misleading (apply.sh dies at step 22 with "pipx:
# command not found" rather than naming the package that broke the
# transaction). apt is more forgiving but a baseline missing still
# cascades. This step fires immediately after the identity-log step
# so forensics keep /etc/nosi-release.
#
# Fast-fail with the list of missing tools, no recovery. The
# operator's next move is to check /var/log/cloud-init.log (or the
# smoketest forensics) for the rejected package name.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 06-package-presence"

# Commands that must exist after cloud-init's package install on every
# shape / variant. Each maps to a package name in every userdata
# packages: list. Keeping the list small so the check is fast and so
# legitimate per-shape additions aren't a maintenance burden.
#
# Fedora ships `pkg-config` from `pkgconf-pkg-config`; apt distros from
# the `pkg-config` package. Both expose `pkg-config` on PATH, so the
# command-based check works.
#
# FreeBSD installs its baseline via nuageinit's packages: list (the
# .user), not pipx/gcc/bsdmake -- clang is base, `make` is bsdmake (we
# install gmake), and there is no pipx in the Phase-2a slice. Check the
# binary names that list actually provides (ripgrep->rg, helix->hx,
# git-delta->delta), same as the smoketest's FreeBSD tool assertion.
case "$NOSI_PKGMGR" in
pkg)
    must_have=(
        git git-lfs curl wget jq python3
        bash gmake cmake ninja meson pkgconf
        hx zellij btop rg fd fzf direnv gh delta
        wg
    )
    ;;
*)
    must_have=(
        git
        git-lfs
        curl
        jq
        python3
        pipx
        make
        gcc
        pkg-config
        wg
    )
    ;;
esac

missing=()
for cmd in "${must_have[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [ ${#missing[@]} -gt 0 ]; then
    nosi_die "cloud-init package install incomplete -- missing baseline tools: ${missing[*]}. \
Likely cause: a typo / nonexistent package name in the variant's cloud-init packages: list caused \
dnf/apt to abort the transaction. Check /var/log/cloud-init.log (or the bake's smoketest-forensics) \
for the rejected name."
fi

# Bake-time tripwire for SILENTLY-dropped packages. cloud-init pre-filters the
# packages: list against the archive, installs what it can, and only WARNS
# about names it could not resolve (renamed/removed, or needing an apt
# component the image's sources don't enable -- this is how the debian images
# shipped for weeks without CPU microcode). That warning lives only in
# /var/log/cloud-init.log, which the end-of-bake `cloud-init clean --logs`
# erases, so it has to be caught HERE while the log still exists (the
# missing-command check above only catches a fully-aborted transaction; a
# partial drop slips past it). Guarded on the log being present so derives
# (chroot, no cloud-init) and FreeBSD (nuageinit) skip it.
if [ -f /var/log/cloud-init.log ] \
    && grep -q 'Failure when attempting to install packages' /var/log/cloud-init.log; then
    nosi_die "cloud-init could not install one or more requested packages (filter warning in \
/var/log/cloud-init.log). A name in the variant's packages: list is unavailable on this \
distro/release -- renamed, dropped, or needs an apt component that isn't enabled. Grep the log \
for 'Failed to install' to see the rejected names."
fi

nosi_info "step 06-package-presence ok"
