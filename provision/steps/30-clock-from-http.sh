#!/usr/bin/env bash
# nosi/provision/steps/30-clock-from-http.sh
#
# Belt-and-braces forward-only clock step for the window between boot and
# NTP convergence. NTP is the primary path (timesyncd on apt, chronyd on
# dnf); this oneshot covers the case where the RTC is so far off that
# anything signature-aware fails before timesyncd has stepped the clock.
#
# Verified-failure case: GMKtec NucBox G10 with a dead CMOS battery boots
# ~6 months in the past. Bake-time clock-epoch floor steps to the bake
# date (still weeks behind real time), and `apt-get update` rejects
# InRelease signatures ("Not live until <future ts>"), `oras pull`
# rejects TLS NotBefore on rotated certs, etc. timesyncd eventually
# fixes it but the boot window before NTP converges is exactly where
# user-visible commands trip.
#
# The oneshot `curl -I`s a public HTTPS endpoint, parses the RFC-7231
# Date: header, and `date -u -s`'es the clock forward IFF we're behind
# by more than 60s. Idempotent (no-op when within 60s), refuses to roll
# backwards (timesyncd is authority for that), best-effort
# `hwclock --systohc` so the correction survives reboot.
#
# Ported from bty's bty-clock-from-http (bty 0.19.6), with the
# bty.server= cmdline path dropped because nosi has no control-plane URL.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 30-clock-from-http (distro=$NOSI_DISTRO)"
nosi_require_root

# ---- FreeBSD: base ntpd + an rc.d HTTP fallback ---------------------------
# ntpd is in the FreeBSD base system, so enable it as the primary clock
# (sync-on-start steps a large initial offset). The HTTP fallback is an
# rc.d oneshot (no systemd). BSD date(1) has no GNU -d/-s: parse the
# RFC-7231 header with `date -ju -f` and set with `date -u <CCYYMMDDhhmm.ss>`.
# Same forward-only, >60s-skew, no-op-when-close semantics as the Linux
# helper. The rc script body uses only double quotes (it is written inside
# a single-quoted heredoc-arg) and grep+sed instead of gawk IGNORECASE
# (FreeBSD awk lacks it).
if [ "$NOSI_DISTRO" = "freebsd" ]; then
    sysrc ntpd_enable="YES" >/dev/null
    sysrc ntpd_sync_on_start="YES" >/dev/null

    nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/30-clock-from-http.sh
# PROVIDE: nosi_clock_from_http
# REQUIRE: NETWORKING
# KEYWORD: firstboot
. /etc/rc.subr
name="nosi_clock_from_http"
rcvar="nosi_clock_from_http_enable"
start_cmd="nosi_clock_from_http_run"
: ${nosi_clock_from_http_enable:=NO}
nosi_clock_from_http_run()
{
    fmt="%a, %d %b %Y %H:%M:%S %Z"
    for url in https://www.google.com/generate_204 https://www.cloudflare.com/cdn-cgi/trace; do
        hdr=$(curl -sS -I --max-time 10 "$url" 2>/dev/null | tr -d "\r" \
            | grep -i "^date:" | head -n1 | sed "s/^[Dd]ate:[[:space:]]*//")
        [ -z "$hdr" ] && continue
        target=$(date -ju -f "$fmt" "$hdr" +%s 2>/dev/null) || continue
        [ -z "$target" ] && continue
        now=$(date -u +%s)
        skew=$((target - now)); abs=${skew#-}
        if [ "$abs" -le 60 ]; then
            echo "nosi-clock-from-http: within 60s of $url; no-op"; return 0
        fi
        if [ "$skew" -lt 0 ]; then
            echo "nosi-clock-from-http: server time behind ours; refusing backwards"; return 0
        fi
        setstr=$(date -ju -r "$target" "+%Y%m%d%H%M.%S")
        if date -u "$setstr" >/dev/null 2>&1; then
            echo "nosi-clock-from-http: stepped clock forward by ${skew}s via $url"; return 0
        fi
    done
    echo "nosi-clock-from-http: no usable Date header from any candidate; clock unchanged"
    return 0
}
load_rc_config $name
run_rc_command "$1"
' /usr/local/etc/rc.d/nosi_clock_from_http 0755
    sysrc nosi_clock_from_http_enable="YES" >/dev/null
    nosi_info "step 30-clock-from-http done (freebsd)"
    exit 0
fi

# ---- 1. nosi-clock-from-http script ---------------------------------------

nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/30-clock-from-http.sh
set -eu
URLS="https://www.google.com/generate_204 https://www.cloudflare.com/cdn-cgi/trace"
for url in $URLS; do
    hdr=$(curl -sS -I --max-time 10 "$url" 2>/dev/null \
        | tr -d "\r" \
        | grep -i "^date:" | head -n1 | sed "s/^[Dd]ate:[[:space:]]*//")
    [ -z "$hdr" ] && continue
    target=$(date -u -d "$hdr" +%s 2>/dev/null || true)
    [ -z "$target" ] && continue
    now=$(date -u +%s)
    skew=$((target - now))
    abs=${skew#-}
    if [ "$abs" -le 60 ]; then
        echo "nosi-clock-from-http: within 60s of $url; no-op"
        exit 0
    fi
    if [ "$skew" -lt 0 ]; then
        echo "nosi-clock-from-http: server time behind ours; refusing to roll backwards"
        exit 0
    fi
    if date -u -s "$hdr" >/dev/null 2>&1; then
        echo "nosi-clock-from-http: stepped clock forward by ${skew}s via $url"
        hwclock --systohc 2>/dev/null || true
        exit 0
    fi
done
echo "nosi-clock-from-http: no usable Date: header from any candidate; clock unchanged"
exit 0
' /usr/local/sbin/nosi-clock-from-http 0755

# ---- 2. systemd unit ------------------------------------------------------

nosi_write_if_changed \
'[Unit]
Description=Step system clock from HTTP Date header (fallback when NTP has not converged)
After=network-online.target systemd-timesyncd.service chronyd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nosi-clock-from-http
RemainAfterExit=yes
TimeoutStartSec=90s

[Install]
WantedBy=multi-user.target
' /etc/systemd/system/nosi-clock-from-http.service 0644

# ---- 3. enable primary NTP daemon + the HTTP fallback --------------------
# Whichever NTP daemon is installed gets enabled. Steps run during bake
# after the packages: list, so the distro's preferred daemon is present.
# On a vanilla Hetzner VM either may be pre-installed; if neither is,
# we leave NTP alone (this step is the HTTP fallback, not the NTP setup).

systemctl daemon-reload

case "$NOSI_PKGMGR" in
apt) systemctl enable systemd-timesyncd.service 2>/dev/null || \
        nosi_warn "systemd-timesyncd not present; HTTP fallback will be sole clock source" ;;
dnf) systemctl enable chronyd.service 2>/dev/null || \
        nosi_warn "chronyd not present; HTTP fallback will be sole clock source" ;;
esac

systemctl enable nosi-clock-from-http.service

nosi_info "step 30-clock-from-http done"
