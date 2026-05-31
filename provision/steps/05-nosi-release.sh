#!/usr/bin/env bash
# nosi/provision/steps/05-nosi-release.sh
#
# Runs FIRST so the build identity is on disk before anything else can
# break. Writes /etc/nosi-release so on any running nosi system the answer
# to "which image-build is this?" is one `cat` away:
#
#     $ cat /etc/nosi-release
#     NOSI_VERSION=2026.05.26-4afcc92
#     NOSI_SHAPE=headless
#     NOSI_VARIANT=ubuntu-2604-headless
#     NOSI_DISTRO=ubuntu
#     NOSI_DISTRO_VERSION=26.04
#     NOSI_BUILT=2026-05-26T14:08:33Z
#
# The motd renderer (step 99, runs last) picks up VERSION + VARIANT from
# this file so the login banner header reads, e.g.,
#
#     nosi headless (ubuntu-2604-headless, 2026.05.26-c2cba6b)   Ubuntu 26.04 LTS ...
#
# Version source (preference order):
#   1. $NOSI_VERSION env var (operator override on a Hetzner-VM re-run)
#   2. /opt/nosi/.nosi-version (written by cijoe/scripts/userdata_render.py
#      at bake time, format YYYY.MM.DD-<7-char-sha>, matches the rolling
#      tag in .github/workflows/build.yml)
#   3. git describe on /opt/nosi if it's a git checkout (Hetzner-VM re-run)
#   4. literal "unknown"
#
# Build timestamp is captured at apply-time, which on the bake path is
# cloud-init runcmd time -- close enough to "when this image was baked"
# for operator diagnostics. Idempotent: re-running on a system whose
# build identity hasn't changed leaves the file (and its mtime) alone.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 05-nosi-release"
nosi_require_root

# Resolve build version.
if [ -n "${NOSI_VERSION:-}" ]; then
    version="$NOSI_VERSION"
elif [ -r /opt/nosi/.nosi-version ]; then
    version="$(head -n1 /opt/nosi/.nosi-version | tr -d '[:space:]')"
elif [ -d /opt/nosi/.git ] && command -v git >/dev/null 2>&1; then
    sha="$(git -C /opt/nosi rev-parse --short=7 HEAD 2>/dev/null || true)"
    if [ -n "$sha" ]; then
        version="$(date -u +%Y.%m.%d)-${sha}"
    else
        version="unknown"
    fi
else
    version="unknown"
fi
[ -n "$version" ] || version="unknown"

shape="${NOSI_SHAPE:-headless}"
variant="${NOSI_VARIANT:-unknown}"
built="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

content="# /etc/nosi-release - written by nosi/provision/steps/05-nosi-release.sh
NOSI_VERSION=${version}
NOSI_SHAPE=${shape}
NOSI_VARIANT=${variant}
NOSI_DISTRO=${NOSI_DISTRO}
NOSI_DISTRO_VERSION=${NOSI_DISTRO_VERSION}
NOSI_BUILT=${built}
"

# nosi_write_if_changed compares content verbatim; NOSI_BUILT churning
# every run would defeat the "skip if unchanged" guarantee, so write the
# whole-minus-built block first, then only refresh NOSI_BUILT if any
# other field actually changed.
stable="# /etc/nosi-release - written by nosi/provision/steps/05-nosi-release.sh
NOSI_VERSION=${version}
NOSI_SHAPE=${shape}
NOSI_VARIANT=${variant}
NOSI_DISTRO=${NOSI_DISTRO}
NOSI_DISTRO_VERSION=${NOSI_DISTRO_VERSION}
"

# If the existing file's stable prefix matches, leave it alone. Otherwise
# write the new content (which includes a fresh NOSI_BUILT).
existing_stable=""
if [ -r /etc/nosi-release ]; then
    existing_stable="$(grep -v '^NOSI_BUILT=' /etc/nosi-release || true)"
    # Strip trailing newline mismatch.
    existing_stable="${existing_stable%$'\n'}"
    stable_trim="${stable%$'\n'}"
    if [ "$existing_stable" = "$stable_trim" ]; then
        nosi_info "step 05-nosi-release done (no identity change; ${version})"
        exit 0
    fi
fi

# /etc is always present; create+chmod portably (BSD install has no -D).
printf '%s' "$content" > /etc/nosi-release
chmod 0644 /etc/nosi-release

nosi_info "step 05-nosi-release done (${variant}, ${version}, built ${built})"
