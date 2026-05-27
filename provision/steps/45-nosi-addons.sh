#!/usr/bin/env bash
# nosi/provision/steps/45-nosi-addons.sh
#
# Install the nosi-addon TUI launcher and the addon collection.
#
# Runs on every shape: addons are operator-launched post-flash via
# `nosi-addon`, not part of the baked apply chain. The addons
# themselves declare shape/distro/version compatibility in a header;
# the launcher reads /etc/nosi-release and filters non-matching
# addons before presenting the menu.
#
# Why this is its own step (not just "leave them under
# /opt/nosi/provision/addons/"): the launcher belongs on PATH at
# /usr/local/bin/nosi-addon, and the addons themselves belong at
# /opt/nosi/addons/ (no /provision/ in the path -- operator-facing).
# userdata_render.py embeds them under /opt/nosi/provision/addons/
# by default; this step copies them out to their proper homes.
#
# Idempotency: install -m overwrites unconditionally; cheap and
# deterministic.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 45-nosi-addons"
nosi_require_root

# Source addons directory (sibling of steps/, populated by
# userdata_render.py via the __NOSI_PROVISION_FILES__ marker).
SRC="$(dirname "$(readlink -f "$0")")/../addons"

# Operator-facing addons home + launcher.
install -d -m 0755 /opt/nosi/addons

# Copy each addon into /opt/nosi/addons/, excluding the launcher
# (which goes to /usr/local/bin/nosi-addon instead).
for addon in "$SRC"/*.sh; do
    name="$(basename "$addon")"
    [ "$name" = "nosi-addon.sh" ] && continue
    install -m 0755 "$addon" "/opt/nosi/addons/$name"
done

# Launcher on PATH (drop the .sh extension).
install -m 0755 "$SRC/nosi-addon.sh" /usr/local/bin/nosi-addon

nosi_info "step 45-nosi-addons done"
