#!/usr/bin/env bash
# nosi-addon: agentic-cli
# description: Node 22 + agentic AI CLIs (claude-code / codex / gemini-cli / opencode) + bash/yaml LSPs + JetBrainsMono Nerd Font
# shapes: headless desktop wsl
# distros: ubuntu debian fedora
# versions: *
#
# Operator-installed post-flash via `nosi-addon` (or direct invocation
# of this script as root). Idempotent: re-running upgrades to latest.
# No reboots required.
#
# This addon replaces the previously-baked "aidev" shape's tooling
# layer (formerly provision/steps/40-nerd-font.sh + 41-npm-globals.sh)
# without baking it into a variant. Operators flash a headless /
# desktop / wsl variant and opt in to agentic-cli at their leisure.

set -euo pipefail

# Re-check eligibility for direct invocations (the TUI launcher
# filters already, but operators can bypass it).
[ -r /etc/nosi-release ] || { echo "agentic-cli: /etc/nosi-release missing" >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/nosi-release

case "${NOSI_DISTRO:-}" in
ubuntu|debian|fedora) ;;
*)
    echo "agentic-cli: unsupported distro '${NOSI_DISTRO:-}' (need ubuntu / debian / fedora)" >&2
    exit 1
    ;;
esac

if [ "$EUID" -ne 0 ]; then
    echo "agentic-cli: re-run with sudo" >&2
    exit 1
fi

# ---- Node 22 LTS ---------------------------------------------------
# Ubuntu/Debian: NodeSource setup_22.x (sets up apt repo + signing key,
# then `apt install nodejs` pulls Node 22 + npm 10). Skips re-setup if
# Node 20+ is already present (covers the case where a future Ubuntu
# release ships a recent-enough Node in main).
# Fedora: dnf install nodejs from the default module stream (44+ ships
# 22.x, so no NodeSource needed).
install_node() {
    local current_major=0
    if command -v node >/dev/null 2>&1; then
        current_major="$(node -v | sed 's/^v\([0-9]\+\).*/\1/')"
    fi
    if [ "$current_major" -ge 20 ]; then
        echo "agentic-cli: node $(node -v) already present, skipping NodeSource"
        return 0
    fi
    case "$NOSI_DISTRO" in
    ubuntu|debian)
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt-get install -y nodejs
        ;;
    fedora)
        dnf install -y nodejs npm
        ;;
    esac
}

# ---- JetBrainsMono Nerd Font --------------------------------------
# Download the latest release tarball and unpack into /usr/local/share.
# fc-cache picks the new fonts up immediately. Idempotent: skipped if
# the destination directory already exists.
install_nerd_font() {
    local dest="/usr/local/share/fonts/JetBrainsMonoNerdFont"
    if [ -d "$dest" ]; then
        echo "agentic-cli: nerd font already at $dest, skipping"
        return 0
    fi
    local url="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    curl -fsSL "$url" -o "$tmp/JetBrainsMono.zip"
    install -d -m 0755 "$dest"
    unzip -q "$tmp/JetBrainsMono.zip" -d "$dest"
    fc-cache -f
}

# ---- npm globals ---------------------------------------------------
# System-wide install under /usr/local/lib/node_modules with shims in
# /usr/local/bin. npm's distro default is /usr (Ubuntu) or /usr/local
# (Fedora); pinning /usr/local keeps apt-managed /usr files untouched
# and the CLIs survive an `apt purge nodejs`. --omit=dev keeps the
# install lean (skips devDependencies of the CLIs).
install_npm_globals() {
    mkdir -p /usr/local/lib/node_modules
    npm config set prefix /usr/local --global
    npm install -g --omit=dev \
        @anthropic-ai/claude-code \
        @openai/codex \
        @google/gemini-cli \
        opencode-ai \
        bash-language-server \
        yaml-language-server
}

install_node
install_nerd_font
install_npm_globals

echo
echo "agentic-cli: done."
echo "  installed CLIs:    claude, codex, gemini, opencode"
echo "  installed LSPs:    bash-language-server, yaml-language-server"
echo "  installed font:    JetBrainsMono Nerd Font"
echo
echo "Re-run nosi-addon any time to refresh to the latest versions."
