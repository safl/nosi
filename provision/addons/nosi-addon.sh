#!/usr/bin/env bash
# nosi-addon : TUI launcher for /opt/nosi/addons/*.sh
#
# Each addon under /opt/nosi/addons/ declares its eligibility in a
# short header (lines starting with `# shapes:`, `# distros:`,
# `# versions:`). nosi-addon reads /etc/nosi-release on the running
# system and only offers addons whose declared compatibility matches.
# Unmatched addons are filtered out before the menu.
#
# Header format (parsed from the addon's first 20-ish lines):
#
#     # nosi-addon: <slug>
#     # description: <one-liner shown in the menu>
#     # shapes: headless desktop wsl     (or *)
#     # distros: ubuntu debian fedora    (or *)
#     # versions: 24.04 26.04            (or *)
#
# Any field can be `*` to mean "any value". Missing fields default to
# `*`. The addon itself should re-check eligibility at the top of its
# body so operators who invoke an addon directly (bypassing the TUI)
# still get a loud failure when on the wrong shape / distro.
#
# Multi-reboot installs (CUDA / ROCm / MLNX_OFED) live as cijoe
# workflows under cijoe/workflows/setup_*.yaml, not as addons --
# nosi-addon is for one-shot, target-local, no-reboot installs.

set -euo pipefail

ADDONS_DIR="/opt/nosi/addons"

# Identity (NOSI_SHAPE / NOSI_DISTRO / NOSI_DISTRO_VERSION) lives in
# /etc/nosi-release, written by step 05-nosi-release during the bake.
# Fail loud if missing -- addons need to know what they're running on.
if [ ! -r /etc/nosi-release ]; then
    echo "nosi-addon: /etc/nosi-release missing; can't determine shape/distro" >&2
    exit 1
fi
# shellcheck disable=SC1091
. /etc/nosi-release

addon_meta() {
    # Read a single header field's value from an addon. Empty if absent.
    local file="$1" field="$2"
    sed -n "s|^# ${field}: ||p" "$file" | head -1 | tr -s ' '
}

matches() {
    # Token match against a space-separated list. `*` in the list (or
    # an empty list) means "any value matches".
    local haystack="${1:-*}" needle="$2"
    [ -z "$haystack" ] && haystack="*"
    local tok
    for tok in $haystack; do
        [ "$tok" = "*" ] && return 0
        [ "$tok" = "$needle" ] && return 0
    done
    return 1
}

shopt -s nullglob
declare -a eligible_names=() eligible_descs=()
for addon in "$ADDONS_DIR"/*.sh; do
    name="$(basename "$addon" .sh)"
    [ "$name" = "nosi-addon" ] && continue

    matches "$(addon_meta "$addon" shapes)"   "${NOSI_SHAPE:-}"          || continue
    matches "$(addon_meta "$addon" distros)"  "${NOSI_DISTRO:-}"         || continue
    matches "$(addon_meta "$addon" versions)" "${NOSI_DISTRO_VERSION:-}" || continue

    desc="$(addon_meta "$addon" description)"
    eligible_names+=("$name")
    eligible_descs+=("${desc:-(no description)}")
done

if [ ${#eligible_names[@]} -eq 0 ]; then
    echo "nosi-addon: no addons eligible for ${NOSI_VARIANT:-this system}."
    echo "(addons live under $ADDONS_DIR and declare shape/distro/version eligibility)"
    exit 0
fi

# Render `name<TAB>description` rows; fzf shows both columns; we keep
# only the name when the user picks.
selected_name=""
selected_line="$(
    paste -d $'\t' \
        <(printf '%s\n' "${eligible_names[@]}") \
        <(printf '%s\n' "${eligible_descs[@]}") \
    | fzf --prompt='nosi-addon> ' \
          --header='Pick an addon. Esc cancels.' \
          --delimiter=$'\t' \
          --with-nth=1,2 \
          --no-multi \
    || true
)"
[ -n "$selected_line" ] || exit 0
selected_name="${selected_line%%$'\t'*}"

addon_path="$ADDONS_DIR/${selected_name}.sh"
echo "nosi-addon: running $addon_path"
if [ "$EUID" -eq 0 ]; then
    exec bash "$addon_path"
else
    exec sudo bash "$addon_path"
fi
