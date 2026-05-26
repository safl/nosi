#!/usr/bin/env bash
# nosi/provision/steps/22-python-tools.sh
#
# Install the opinionated helix LSP / linter / formatter stack and the
# user space PCI helpers (DPDK/SPDK and xNVMe/uPCIe ergonomics) via
# pipx, system-wide:
#
#   ruff      -- linter + formatter, includes built-in `ruff server` LSP
#   pyright   -- type-checking LSP (`pyright-langserver`)
#   devbind   -- sysfs PCI driver-binding manager (github.com/xnvme/devbind)
#   hugepages -- Linux hugepages inspection + reservation (github.com/xnvme/hugepages)
#   iommu     -- manage the Linux IOMMU substrate via the kernel cmdline (github.com/safl/iommu)
#
# pipx gives each CLI its own venv (no dependency conflicts between e.g.
# ruff's pinned pyproject-tooling deps and devbind's), and matches the
# pattern we already use for cijoe itself. Install system-wide via
# `pipx install --global` (pipx 1.5+), which puts venvs under
# /usr/local/pipx and symlinks into /usr/local/bin. /usr/local/bin is
# already on every user's PATH, so no profile.d wiring needed -- and
# pipx itself owns the symlinks, so `pipx uninstall --global` /
# `pipx list --global` stay consistent.
#
# Bash completions are written into /etc/bash_completion.d/ so they
# autoload on interactive shells (via the bash-completion package's
# loader).
#
# Idempotency: `pipx upgrade || pipx install` upgrades on re-run if the
# package is already present, else fresh-installs. Matches the Hetzner-VM
# "update everything to upstream latest" semantics already established
# by step 20.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 22-python-tools"
nosi_require_root

# ---- pipx-installed CLIs --------------------------------------------------
#
# Fail-fast on first pipx error. apply.sh runs under set -e and the bake
# is gated on /etc/nosi/apply-ok; a missing tool here aborts the whole
# bake by design. If a PyPI fetch goes 404 we want the build to fail
# loudly, not produce an image missing devbind / iommu / ruff.

# pipx install errors when the package is already installed, so the
# Hetzner-VM "re-run upgrades everything" pattern needs upgrade-with-
# install-fallback. set -e is still in effect: if both branches fail
# (e.g. PyPI 404), the step aborts and apply.sh aborts the bake.
for pkg in ruff pyright devbind hugepages iommu; do
    if pipx list --global --short 2>/dev/null | awk '{print $1}' | grep -qx "$pkg"; then
        pipx upgrade --global "$pkg"
    else
        pipx install --global "$pkg"
    fi
done

# ---- bash completions for the PCI helpers --------------------------------

install -d -m 0755 /etc/bash_completion.d
for t in iommu devbind hugepages; do
    $t --print-completion bash > /etc/bash_completion.d/$t 2>/dev/null || true
done

nosi_info "step 22-python-tools done"
