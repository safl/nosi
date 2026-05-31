#!/usr/bin/env bash
# nosi/provision/steps/22-python-tools.sh
#
# Install the opinionated helix LSP / linter / formatter stack, the
# user space PCI helpers (DPDK/SPDK and xNVMe/uPCIe ergonomics), and the
# cijoe orchestration tool with pipx, system-wide:
#
#   ruff      -- linter + formatter, includes built-in `ruff server` LSP
#   pyright   -- type-checking LSP (`pyright-langserver`)
#   devbind   -- sysfs PCI driver-binding manager (github.com/xnvme/devbind)
#   hugepages -- Linux hugepages inspection + reservation (github.com/xnvme/hugepages)
#   iommu     -- manage the Linux IOMMU substrate via the kernel cmdline (github.com/safl/iommu)
#   cijoe     -- task/workflow orchestration (github.com/refenv/cijoe); the
#                tool nosi + bty are built with, baked into every shape so a
#                nosi system can drive qemu-guest / test workflows out of the
#                box. The docker shape (OCI bootstrap host) leans on it most,
#                but it's a base tool, not a docker-only one.
#
# pipx is the right tool for this (per-tool isolated venvs + managed
# shims) and `pipx install --global` is its first-class system-wide
# idiom -- venvs in /opt/pipx, shims in /usr/local/bin, no env-var
# plumbing, `pipx list/upgrade/uninstall --global` stay consistent.
#
# The catch: --global is pipx 1.5+, and noble (24.04) ships pipx 1.4.
# So we reach a modern pipx via `uvx pipx` -- uvx (installed in step 20
# alongside uv) runs the latest pipx ephemerally, regardless of the
# distro's pipx version. The distro pipx stays installed for operators'
# own per-user use; this step is purely the system-wide install path.
#
# --python pins the tool venvs to the stable system interpreter.
# Without it, pipx-run-under-uvx could bind venvs to uv's ephemeral
# Python, which would rot when uv GCs its cache.
#
# Idempotency: upgrade-if-present else install, fetching latest on a
# re-run -- the Hetzner-VM "update everything to upstream latest"
# semantics already established by step 20. set -e in apply.sh aborts
# the bake if any fetch fails.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 22-python-tools"
nosi_require_root

# ---- FreeBSD: ruff via pkg; the rest are Python-packaging casualties ------
# ruff ships a FreeBSD-native binary in ports (a PyPI install would
# source-build the Rust), so use pkg -- that is the one tool that lands
# cleanly. The others are deferred on FreeBSD:
#   * cijoe: uvx/pipx install fails ("Fatal error from uv") because its
#     deps have no FreeBSD wheels and source-build, and it is not in ports;
#   * pyright: Node-based, excluded by the no-node policy (agentic-cli
#     add-on), and FreeBSD has no upstream node for its nodeenv fetch;
#   * devbind/hugepages/iommu: Linux sysfs/vfio/kernel-cmdline tools with
#     no FreeBSD analogue.
# An operator who needs cijoe can install it into a venv by hand.
if [ "$NOSI_DISTRO" = "freebsd" ]; then
    nosi_pkg_install ruff
    nosi_info "step 22-python-tools done (freebsd)"
    exit 0
fi

command -v uvx >/dev/null 2>&1 || nosi_die "uvx not on PATH (step 20 installs uv + uvx)"
py="$(command -v python3)" || nosi_die "python3 not on PATH"

for pkg in ruff pyright devbind hugepages iommu cijoe; do
    if uvx pipx list --global --short 2>/dev/null | awk '{print $1}' | grep -qx "$pkg"; then
        uvx pipx upgrade --global "$pkg"
    else
        uvx pipx install --global --python "$py" "$pkg"
    fi
done

# ---- bash completions for the PCI helpers --------------------------------

install -d -m 0755 /etc/bash_completion.d
for t in iommu devbind hugepages; do
    "$t" --print-completion bash > /etc/bash_completion.d/$t 2>/dev/null || true
done

nosi_info "step 22-python-tools done"
