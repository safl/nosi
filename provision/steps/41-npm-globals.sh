#!/usr/bin/env bash
# nosi/provision/steps/41-npm-globals.sh
#
# aidev only. Install the agentic-AI CLIs and Node-based LSPs globally
# via npm:
#
#   @anthropic-ai/claude-code   (claude)
#   @openai/codex
#   @google/gemini-cli          (gemini)
#   opencode-ai                 (opencode)
#   bash-language-server
#   yaml-language-server
#
# System-wide install under /usr/local/lib/node_modules with shims in
# /usr/local/bin. npm's global prefix on Ubuntu is /usr by default; we
# repoint to /usr/local so apt-managed /usr files stay untouched and the
# CLIs survive an Ubuntu npm purge. The bash + yaml LSPs ship here (not
# on headless) because they require Node, which headless intentionally
# doesn't carry.
#
# Idempotency: npm install -g upgrades to the registry-latest each run,
# matching the Hetzner-VM "update everything to upstream latest"
# semantics already established by step 20.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 41-npm-globals (shape=${NOSI_SHAPE:-?})"

if [ "${NOSI_SHAPE:-}" != "aidev" ]; then
    nosi_info "non-aidev shape; skipping"
    exit 0
fi

nosi_require_root
command -v npm >/dev/null 2>&1 || nosi_die "npm not on PATH (aidev requires nodejs+npm)"

mkdir -p /usr/local/lib/node_modules
npm config set prefix /usr/local --global
npm install -g --omit=dev \
    @anthropic-ai/claude-code \
    @openai/codex \
    @google/gemini-cli \
    opencode-ai \
    bash-language-server \
    yaml-language-server

claude --version 2>/dev/null || claude-code --version 2>/dev/null || true
codex --version 2>/dev/null || true
gemini --version 2>/dev/null || true
opencode --version 2>/dev/null || true
bash-language-server --version 2>/dev/null || true
yaml-language-server --version 2>/dev/null || true

nosi_info "step 41-npm-globals done"
