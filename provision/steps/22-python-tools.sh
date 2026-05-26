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
# Fail-fast on first pip error. An earlier iteration installed each
# package in its own pip call with warn-and-continue, so one bad / 404
# package left the image looking baked but missing tools. apply.sh now
# fail-fasts under set -e and the bake is gated on /etc/nosi/apply-ok,
# so a missing tool here aborts the whole bake by design -- that is the
# point. If a package goes 404 we want the build to fail loudly and the
# operator to fix the index, not for the image to ship without claude /
# devbind / iommu.

python3 -m venv /opt/python-tools
/opt/python-tools/bin/pip install --no-cache-dir --upgrade pip
/opt/python-tools/bin/pip install --no-cache-dir --upgrade \
    ruff pyright devbind hugepages iommu

for bin in ruff pyright pyright-langserver devbind hugepages iommu; do
    ln -sf "/opt/python-tools/bin/$bin" "/usr/local/bin/$bin"
done

# ---- bash completions for the PCI helpers --------------------------------

install -d -m 0755 /etc/bash_completion.d
for t in iommu devbind hugepages; do
    $t --print-completion bash > /etc/bash_completion.d/$t 2>/dev/null || true
done

nosi_info "step 22-python-tools done"
