#!/usr/bin/env bash
# nosi/provision/steps/22-python-tools.sh
#
# Shared /opt/python-tools venv with the opinionated helix LSP / linter /
# formatter stack and the user space PCI helpers (DPDK/SPDK and
# xNVMe/uPCIe ergonomics):
#
#   ruff      -- linter + formatter, includes built-in `ruff server` LSP
#   pyright   -- type-checking LSP (`pyright-langserver`)
#   devbind   -- sysfs PCI driver-binding manager (github.com/xnvme/devbind)
#   hugepages -- Linux hugepages inspection + reservation (github.com/xnvme/hugepages)
#   iommu     -- manage the Linux IOMMU substrate via the kernel cmdline (github.com/safl/iommu)
#
# Each console script is symlinked into /usr/local/bin so every user gets
# them on PATH without setup. Bash completions are written into
# /etc/bash_completion.d/ so they autoload on interactive shells (via the
# bash-completion package's loader).
#
# Idempotency: `python3 -m venv` is a no-op if /opt/python-tools already
# exists; pip --upgrade picks up newer versions, which is the intent on
# re-run (same Hetzner-VM "update everything" semantics as step 20).

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 22-python-tools"
nosi_require_root

# ---- venv + tools ---------------------------------------------------------
#
# Install each package independently so a single bad / unreachable index
# entry can't take down the rest. Previously the bundled `pip install ruff
# pyright devbind hugepages iommu` was a single atomic call -- one network
# blip aborted the whole step under apply.sh's old set -e, and every step
# after this (sshd-enable, motd, firstboot-inventory, ...) silently never
# ran. The per-package loop with warn-on-failure keeps the rest moving and
# leaves a clear marker in the bake log of exactly which package broke.

python3 -m venv /opt/python-tools

if ! /opt/python-tools/bin/pip install --no-cache-dir --upgrade pip; then
    nosi_warn "pip upgrade failed (continuing with bundled pip)"
fi

PIP_PKGS=(ruff pyright devbind hugepages iommu)
for pkg in "${PIP_PKGS[@]}"; do
    if /opt/python-tools/bin/pip install --no-cache-dir --upgrade "$pkg"; then
        nosi_info "installed $pkg"
    else
        nosi_warn "failed to install $pkg (continuing)"
    fi
done

# Symlink whatever console scripts the install actually produced; missing
# ones are warned about, not fatal, so a partial install still wires up
# the bits that worked.
for bin in ruff pyright pyright-langserver devbind hugepages iommu; do
    if [ -x "/opt/python-tools/bin/$bin" ]; then
        ln -sf "/opt/python-tools/bin/$bin" "/usr/local/bin/$bin"
    else
        nosi_warn "/opt/python-tools/bin/$bin missing; no /usr/local/bin symlink"
    fi
done

# ---- bash completions for the PCI helpers --------------------------------

install -d -m 0755 /etc/bash_completion.d
for t in iommu devbind hugepages; do
    $t --print-completion bash > /etc/bash_completion.d/$t 2>/dev/null || true
done

nosi_info "step 22-python-tools done"
