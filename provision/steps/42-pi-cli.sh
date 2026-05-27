#!/usr/bin/env bash
# nosi/provision/steps/42-pi-cli.sh
#
# aidev only. Install the `pi` CLI (https://pi.dev). Curl-piped installer
# run as root so the binary lands in a system path. The installer is
# opaque w.r.t. version pinning; if reproducibility bites we switch to a
# pinned URL.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 42-pi-cli (shape=${NOSI_SHAPE:-?})"

if [ "${NOSI_SHAPE:-}" != "aidev" ]; then
    nosi_info "non-aidev shape; skipping"
    exit 0
fi

nosi_require_root

curl -fsSL https://pi.dev/install.sh | sh
command -v pi >/dev/null 2>&1 && pi --version || true

nosi_info "step 42-pi-cli done"
