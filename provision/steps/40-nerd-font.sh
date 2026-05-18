#!/usr/bin/env bash
# nosi/provision/steps/40-nerd-font.sh
#
# aidev only. Install JetBrainsMono Nerd Font system-wide.
#
# The font itself only matters for rendering paths that exist on the
# box: X/Wayland apps (e.g. wslg on WSL2), the framebuffer console with
# a tool that loads OTF, or X-forwarded SSH. SSH-only operators get no
# benefit from the font being on the server: their local terminal does
# the rendering. Ships on aidev because WSL is a primary target and
# wslg is the most likely rendering path.
#
# Requires fontconfig (provides fc-cache); aidev's package list has it.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 40-nerd-font (flavor=${NOSI_FLAVOR:-?})"

if [ "${NOSI_FLAVOR:-}" != "aidev" ]; then
    nosi_info "non-aidev flavor; skipping"
    exit 0
fi

nosi_require_root

dest=/usr/local/share/fonts/JetBrainsMonoNerdFont
mkdir -p "$dest"
curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz \
    | tar -xJ -C "$dest"
fc-cache -f >/dev/null 2>&1 || true
fc-list 2>/dev/null | grep -i 'JetBrainsMono Nerd' | head -n1 || true

nosi_info "step 40-nerd-font done"
