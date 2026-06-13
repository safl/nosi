#!/usr/bin/env bash
# nosi/provision/steps/95-selfcheck.sh
#
# Installs /usr/local/bin/nosi-selfcheck, an operator-facing health-check that
# verifies the live system matches a healthy nosi image. Runs in FINAL_STEPS so
# it lands on every shape, the shape derive, and FreeBSD. The check is a
# read-only POSIX-sh script; the smoketest runs the same binary on the booted
# image so CI and operators validate the box from one definition.
#
# The script body goes in a QUOTED heredoc so no shell expansion or
# quote-escaping happens here -- what is below is exactly what ships.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 95-selfcheck (distro=$NOSI_DISTRO)"
nosi_require_root

install -d -m 0755 /usr/local/bin

cat > /usr/local/bin/nosi-selfcheck <<'NOSI_SELFCHECK'
#!/bin/sh
# Managed by nosi/provision/steps/95-selfcheck.sh
# nosi-selfcheck: verify the live system matches a healthy nosi image.
# Read-only and idempotent. Prints [PASS]/[FAIL]/[SKIP] per check and exits
# non-zero if any check FAILED (SKIP never fails). Run after flashing
# (sudo nosi-selfcheck enables the root-only checks) to confirm the box came
# up as expected; CI runs it on the booted smoketest image too.
set -u

p=0 f=0 s=0
PASS() { printf '  [PASS] %s\n' "$1"; p=$((p + 1)); }
FAIL() { printf '  [FAIL] %s\n' "$1"; f=$((f + 1)); }
SKIP() { printf '  [SKIP] %s\n' "$1"; s=$((s + 1)); }

shape=$(cat /etc/nosi/shape 2>/dev/null || echo unknown)
variant=unknown version=unknown
if [ -r /etc/nosi-release ]; then
    while IFS='=' read -r k v; do
        [ "$k" = NOSI_VARIANT ] && variant=$v
        [ "$k" = NOSI_VERSION ] && version=$v
    done < /etc/nosi-release
fi
printf 'nosi-selfcheck: %s (%s)  shape=%s\n' "$variant" "$version" "$shape"

have_systemd=0
[ -d /run/systemd/system ] && have_systemd=1

# Run a root-only command non-interactively (image gives odus NOPASSWD sudo);
# returns non-zero without prompting if root access is unavailable.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif command -v sudo >/dev/null 2>&1; then sudo -n "$@" 2>/dev/null
    else return 127
    fi
}

if [ -s /etc/nosi/apply-ok ]; then
    PASS "provision chain completed (apply-ok present)"
else
    FAIL "apply-ok sentinel missing: provision did not finish"
fi

if [ "$(uname -s)" = FreeBSD ]; then
    tools="git hx zellij rg jq uv oras lazygit wg"
else
    tools="git hx zellij lazygit yazi oras uv ruff cijoe rg wg"
fi
miss=
for t in $tools; do
    command -v "$t" >/dev/null 2>&1 || miss="$miss $t"
done
if [ -z "$miss" ]; then
    PASS "baseline tools on PATH"
else
    FAIL "tools missing from PATH:$miss"
fi

rootline=$(as_root grep '^root:' /etc/shadow 2>/dev/null || true)
if [ -z "$rootline" ]; then
    SKIP "root-lock check (needs root, or no /etc/shadow): try sudo nosi-selfcheck"
else
    h=$(printf '%s' "$rootline" | cut -d: -f2)
    case "$h" in
        '!'* | '*'*) PASS "root account is locked" ;;
        *) FAIL "root account is NOT locked" ;;
    esac
fi

case "$shape" in
headless | desktop | proxmox)
    if [ "$have_systemd" -eq 1 ]; then
        en=$(systemctl is-enabled nosi-growroot.service 2>/dev/null || true)
        fa=$(systemctl is-failed nosi-growroot.service 2>/dev/null || true)
        if [ "$en" = enabled ] && [ "$fa" != failed ]; then
            PASS "nosi-growroot enabled (rootfs expands on first boot)"
        else
            FAIL "nosi-growroot not healthy (is-enabled=$en is-failed=$fa)"
        fi
        if systemctl is-enabled ssh.service ssh.socket sshd.service 2>/dev/null | grep -qx enabled; then
            PASS "ssh enabled for boot"
        else
            FAIL "ssh service not enabled"
        fi
    else
        SKIP "systemd unit checks (no running systemd)"
    fi
    if command -v ss >/dev/null 2>&1; then
        if ss -Hltn 'sport = :22' 2>/dev/null | grep -q .; then
            PASS "sshd listening on :22"
        else
            FAIL "nothing listening on :22"
        fi
    else
        SKIP "sshd-listening check (ss unavailable)"
    fi
    if command -v lsmod >/dev/null 2>&1; then
        if lsmod 2>/dev/null | grep -qw nouveau; then
            FAIL "nouveau loaded despite blacklist"
        else
            PASS "nouveau not loaded (blacklist honored)"
        fi
    else
        SKIP "nouveau check (lsmod unavailable)"
    fi
    if command -v tailscale >/dev/null 2>&1 && [ "$have_systemd" -eq 1 ]; then
        ten=$(systemctl is-enabled tailscaled.service 2>/dev/null || true)
        if [ "$ten" = disabled ]; then
            PASS "tailscaled installed and dormant"
        else
            FAIL "tailscaled is '$ten', expected disabled (ships dormant)"
        fi
    fi
    ;;
*)
    SKIP "bare-metal checks not applicable to shape=$shape"
    ;;
esac

if [ "$shape" = proxmox ] && [ "$have_systemd" -eq 1 ]; then
    if systemctl is-active pve-cluster pvedaemon pveproxy >/dev/null 2>&1; then
        PASS "Proxmox VE daemons active"
    else
        FAIL "one or more PVE daemons not active"
    fi
    if command -v ss >/dev/null 2>&1 && ss -Hltn 'sport = :8006' 2>/dev/null | grep -q .; then
        PASS "Proxmox web UI listening on :8006"
    else
        FAIL "pveproxy (:8006) not listening"
    fi
fi
if [ "$shape" = desktop ] && [ "$have_systemd" -eq 1 ]; then
    if systemctl is-enabled display-manager.service >/dev/null 2>&1; then
        PASS "display manager (greeter) enabled"
    else
        FAIL "display-manager.service not enabled"
    fi
    # `is-enabled` does NOT catch greetd crash-looping because the
    # greeter user its config names is absent -- the box then hits the
    # start limit and drops to a text login (the apt/dnf packages create
    # _greetd / a sysusers user, not necessarily the configured one, and
    # that creation may not fire in the derive chroot). Verify the user
    # greetd is configured to run as actually exists.
    greeter_user=$(sed -n 's/^user *= *"\(.*\)".*/\1/p' /etc/greetd/config.toml 2>/dev/null | head -1)
    greeter_user=${greeter_user:-greeter}
    if getent passwd "$greeter_user" >/dev/null 2>&1; then
        PASS "greetd greeter user '$greeter_user' exists"
    else
        FAIL "greetd greeter user '$greeter_user' missing (greetd will crash-loop)"
    fi
fi

if [ -f /etc/nosi/default-password-active ]; then
    SKIP "operator still on default password 'odus.321' (rotate: sudo passwd odus)"
fi

printf '%d passed, %d failed, %d skipped\n' "$p" "$f" "$s"
[ "$f" -eq 0 ]
NOSI_SELFCHECK

chmod 0755 /usr/local/bin/nosi-selfcheck

nosi_info "step 95-selfcheck done"
