#!/usr/bin/env bash
# nosi/provision/steps/05-nosi-release.sh
#
# Runs FIRST so the build identity is on disk before anything else can
# break. Writes /etc/nosi-release so on any running nosi system the answer
# to "which image-build is this?" is one `cat` away:
#
#     $ cat /etc/nosi-release
#     NOSI_VERSION=2026.W25
#     NOSI_SHAPE=headless
#     NOSI_VARIANT=ubuntu-2604-headless
#     NOSI_DISTRO=ubuntu
#     NOSI_DISTRO_VERSION=26.04
#     NOSI_BUILT=2026-06-19T05:00:00Z
#
# The motd renderer (step 99, runs last) picks up VERSION + VARIANT from
# this file so the login banner header reads, e.g.,
#
#     nosi headless (ubuntu-2604-headless, 2026.W25)   Ubuntu 26.04 LTS ...
#
# Version source (preference order):
#   1. $NOSI_VERSION env var (operator override on a Hetzner-VM re-run)
#   2. /opt/nosi/.nosi-version (written by cijoe/scripts/userdata_render.py
#      at bake time, format YYYY.WNN, matches the ISO-week rolling tag
#      in .github/workflows/build.yml)
#   3. date -u +'%G.W%V' on /opt/nosi if it's a git checkout (Hetzner-VM
#      re-run, same format as #2)
#   4. literal "unknown"
#
# Build timestamp is captured at apply-time, which on the bake path is
# cloud-init runcmd time, close enough to "when this image was baked"
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
elif [ -d /opt/nosi/.git ]; then
    # Match userdata_render.py + build.yml: ISO-week tag, time-derived,
    # no git short-sha appended.
    version="$(date -u +'%G.W%V' 2>/dev/null || true)"
    [ -n "$version" ] || version="unknown"
else
    version="unknown"
fi
[ -n "$version" ] || version="unknown"

shape="${NOSI_SHAPE:-headless}"
variant="${NOSI_VARIANT:-unknown}"
built="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- default hostname: nosi-<variant> ---------------------------------------
# Set here (ALWAYS_FIRST, runs in every path) rather than in the base-only
# 08-network-dhcp so each DERIVE stamps its OWN variant name: the desktop /
# proxmox derive overrides the headless base's name instead of inheriting it
# (a `--shape-only` run re-exports the derived NOSI_VARIANT). Claim the
# hostname only when it is still a nosi-managed default -- a known placeholder
# (incl. Raspberry Pi OS's `raspberrypi`, which the old 08 list missed) or a
# prior `nosi-*` name -- so a name an operator deliberately chose (anything not
# starting `nosi-`) survives an apply.sh re-run on a live box.
if [ "$variant" != "unknown" ]; then
    want_hn="nosi-${variant}"
    if [ "${NOSI_DISTRO:-}" = "freebsd" ]; then
        cur_hn="$(sysrc -n hostname 2>/dev/null || hostname 2>/dev/null || true)"
        case "${cur_hn:-}" in
        "" | localhost | localhost.localdomain | nosi-build | freebsd | nosi-*)
            sysrc hostname="$want_hn" >/dev/null 2>&1 || true
            nosi_info "hostname set to ${want_hn} (was: ${cur_hn:-empty})"
            ;;
        esac
    else
        cur_hn="$(cat /etc/hostname 2>/dev/null || true)"
        case "${cur_hn:-}" in
        "" | localhost | localhost.localdomain | nosi-build | raspberrypi | nosi-*)
            printf '%s\n' "$want_hn" > /etc/hostname
            # Keep 127.0.1.1 resolvable: sudo warns without it, and pmxcfs
            # (proxmox) refuses to start unless the node name resolves.
            if [ -f /etc/hosts ]; then
                if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
                    sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${want_hn}.localdomain ${want_hn}/" /etc/hosts
                else
                    printf '127.0.1.1\t%s.localdomain %s\n' "$want_hn" "$want_hn" >> /etc/hosts
                fi
            fi
            nosi_info "hostname set to ${want_hn} (was: ${cur_hn:-empty})"
            ;;
        esac
        # The seed that set cloud-init's `hostname:` is consumed at bake; on
        # the operator's first flash-boot cloud-init's set-hostname module
        # would otherwise revert /etc/hostname. Preserve the baked name.
        if [ -d /etc/cloud ]; then
            install -d -m 0755 /etc/cloud/cloud.cfg.d
            printf '# Managed by nosi/provision/steps/05-nosi-release.sh\npreserve_hostname: true\n' \
                > /etc/cloud/cloud.cfg.d/95-nosi-hostname.cfg
            chmod 0644 /etc/cloud/cloud.cfg.d/95-nosi-hostname.cfg
        fi
    fi
fi

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
