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

# ---- FreeBSD: ruff (pkg) + cijoe (venv reusing pkg-prebuilt deps) ---------
# ruff ships a FreeBSD-native binary in ports (a PyPI install would
# source-build the Rust), so use pkg. cijoe is pure-Python and light, but it
# pulls paramiko -> cryptography (Rust) and pyyaml/psutil (C); on FreeBSD
# there are no PyPI wheels, so a plain pipx/uv install source-builds those
# and fails (cryptography needs Rust, which we deliberately do not bake).
# Fix: install the deps that NEED a native toolchain -- paramiko (-> the
# Rust-built cryptography) and psutil (C) -- from pkg (prebuilt by the ports
# cluster, small, no llvm/Rust at runtime), then create a venv with
# --system-site-packages so it reuses them and pip only adds the rest. pyyaml
# is left to pip: it has a pure-Python fallback when libyaml/Cython are
# absent, so no pkg (and no FreeBSD-named yaml port) is needed. pkg names are
# python-version-flavored, so derive the prefix. pyright is excluded (Node,
# no-node policy); devbind/hugepages/iommu are Linux sysfs/vfio tools.
if [ "$NOSI_DISTRO" = "freebsd" ]; then
    nosi_pkg_install ruff
    pyver="$(python3 -c 'import sys; print(f"py{sys.version_info.major}{sys.version_info.minor}")')"
    # cijoe's import-time deps beyond the Rust-native pair: jinja2
    # (template rendering) + yaml (config) + markupsafe (jinja2's
    # C-accelerated escape). All ship as native FreeBSD ports so the
    # pkg install path never touches Rust. Adding them here keeps
    # cijoe's --no-deps install (below) safe: pkg supplies every
    # module cijoe imports at startup.
    nosi_pkg_install "${pyver}-paramiko" "${pyver}-psutil" \
        "${pyver}-Jinja2" "${pyver}-yaml" "${pyver}-MarkupSafe"
    [ -x /opt/nosi/cijoe-venv/bin/python ] \
        || python3 -m venv --system-site-packages /opt/nosi/cijoe-venv
    # ``--no-deps`` is essential on FreeBSD: pip's resolver otherwise
    # decides at least one of cijoe's transitives (via cryptography's
    # PEP 517 build-system.requires) needs maturin, has no FreeBSD
    # PyPI wheel, and tries to source-build. That source build wedges
    # on ``Rust not found`` because we deliberately don't ship Rust.
    # cijoe itself is pure Python; the runtime deps it actually
    # imports (paramiko, psutil, pyyaml) are covered by the pkg
    # ports installed above (pyyaml has a pure-Python fallback). If
    # cijoe ever adds a new dep, ``cijoe --version`` below fails
    # loudly at bake time with an ImportError so the miss is
    # observable, not silent.
    /opt/nosi/cijoe-venv/bin/pip install --upgrade --no-deps --quiet cijoe
    ln -sf /opt/nosi/cijoe-venv/bin/cijoe /usr/local/bin/cijoe
    cijoe --version
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
