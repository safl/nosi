#!/usr/bin/env bash
# nosi/provision/steps/22-python-tools.sh
#
# Install the opinionated helix LSP / linter / formatter stack and the
# user space PCI helpers (DPDK/SPDK and xNVMe/uPCIe ergonomics) into a
# shared venv at /opt/python-tools, with each tool's entry-point
# symlinked into /usr/local/bin:
#
#   ruff      -- linter + formatter, includes built-in `ruff server` LSP
#   pyright   -- type-checking LSP (`pyright-langserver`)
#   devbind   -- sysfs PCI driver-binding manager (github.com/xnvme/devbind)
#   hugepages -- Linux hugepages inspection + reservation (github.com/xnvme/hugepages)
#   iommu     -- manage the Linux IOMMU substrate via the kernel cmdline (github.com/safl/iommu)
#
# Why a shared venv rather than `pipx install --global`: noble's pipx
# is 1.4 (lacks --global, which only landed in 1.5). A bare-venv +
# symlinks approach is portable across every pipx version + every
# distro. /usr/local/bin is already on every user's PATH so no
# profile.d wiring is needed.
#
# Bash completions are written into /etc/bash_completion.d/ so they
# autoload on interactive shells (via the bash-completion package's
# loader).
#
# Idempotency: pip install --upgrade fetches latest on every re-run,
# matching the Hetzner-VM "update everything to upstream latest"
# semantics already established by step 20.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 22-python-tools"
nosi_require_root

VENV=/opt/python-tools
PKGS=(ruff pyright devbind hugepages iommu)

# Create venv on first run. python3 + ensurepip module is enough; no
# extra packages needed from the distro side.
if [ ! -x "$VENV/bin/pip" ]; then
    python3 -m venv "$VENV"
fi

# Fetch pip-latest first so pip can resolve newer packaging features
# the tools may use, then install/upgrade the tool set in one pip call
# (faster + lets pip resolve a consistent dependency graph across all
# tools).
"$VENV/bin/pip" install --upgrade --quiet pip
"$VENV/bin/pip" install --upgrade --quiet "${PKGS[@]}"

# Symlink every entry-point script the venv exposes into /usr/local/bin,
# minus the venv's own Python plumbing. ln -sf re-points existing
# symlinks on a re-run (e.g., after a venv-recreation).
for f in "$VENV"/bin/*; do
    name=$(basename "$f")
    case "$name" in
        python*|pip*|activate*|*.pyc|wheel) continue ;;
    esac
    ln -sf "$f" "/usr/local/bin/$name"
done

# ---- bash completions for the PCI helpers --------------------------------

install -d -m 0755 /etc/bash_completion.d
for t in iommu devbind hugepages; do
    "$VENV/bin/$t" --print-completion bash > /etc/bash_completion.d/$t 2>/dev/null || true
done

nosi_info "step 22-python-tools done"
