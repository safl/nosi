# shellcheck shell=bash
# nosi/provision/lib/common.sh
#
# Sourced by every step under provision/steps/. Provides distro detection,
# a thin package-manager wrapper, logging, and small idempotency helpers.
#
# Steps are written to be:
#   * standalone (executable on their own, no apply.sh required)
#   * idempotent (running twice does nothing the second time)
#   * cross-distro where the work is genuinely the same (DKMS, modprobe.d,
#     systemd units, /etc/profile.d snippets); per-distro otherwise.
#
# Source from a step with:
#   . "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

set -euo pipefail

# ---- distro detection ------------------------------------------------------
# NOSI_DISTRO is one of: debian, ubuntu, fedora.
# NOSI_PKGMGR is one of: apt, dnf.
# Steps that need finer granularity (e.g. trixie vs noble) can read /etc/os-release directly.

nosi_detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        NOSI_DISTRO="${ID:-unknown}"
        NOSI_DISTRO_VERSION="${VERSION_ID:-unknown}"
    else
        NOSI_DISTRO="unknown"
        NOSI_DISTRO_VERSION="unknown"
    fi

    case "$NOSI_DISTRO" in
        debian|ubuntu) NOSI_PKGMGR=apt ;;
        fedora)        NOSI_PKGMGR=dnf ;;
        *) nosi_die "unsupported distro: $NOSI_DISTRO (need debian, ubuntu, or fedora)" ;;
    esac

    export NOSI_DISTRO NOSI_DISTRO_VERSION NOSI_PKGMGR
}

# ---- logging ---------------------------------------------------------------

nosi_info() { printf '[nosi] %s\n' "$*"; }
nosi_warn() { printf '[nosi] WARN: %s\n' "$*" >&2; }
nosi_die()  { printf '[nosi] FATAL: %s\n' "$*" >&2; exit 1; }

# ---- environment guards ----------------------------------------------------

nosi_require_root() {
    [ "$(id -u)" -eq 0 ] || nosi_die "must run as root (use sudo)"
}

# WSL has no real kernel headers and DKMS is meaningless. Steps that build
# kernel modules should bail early on WSL.
nosi_is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

# ---- package manager wrapper ----------------------------------------------
# Synchronous, non-interactive install. Idempotent in the sense that apt/dnf
# already no-op on already-installed packages.

nosi_pkg_install() {
    [ "$#" -gt 0 ] || return 0
    case "$NOSI_PKGMGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        dnf) dnf install -y "$@" ;;
        *)   nosi_die "no package manager wired for $NOSI_PKGMGR" ;;
    esac
}

# Is a package installed? Returns 0 yes / 1 no.
nosi_pkg_installed() {
    case "$NOSI_PKGMGR" in
        apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
        dnf) rpm -q "$1" >/dev/null 2>&1 ;;
        *)   return 1 ;;
    esac
}

# ---- idempotency helpers ---------------------------------------------------

# Write $1 contents to $2 with mode $3, but only if contents differ. Useful
# to avoid touching mtimes on /etc files that other tools watch.
nosi_write_if_changed() {
    local content="$1" path="$2" mode="${3:-0644}"
    if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
        return 0
    fi
    install -D -m "$mode" /dev/null "$path"
    printf '%s' "$content" > "$path"
}

# Auto-detect on source. Callers can re-run if they need to refresh.
nosi_detect_distro
