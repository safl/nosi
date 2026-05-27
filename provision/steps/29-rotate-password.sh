#!/usr/bin/env bash
# nosi/provision/steps/29-rotate-password.sh
#
# Mark the system as running with the baked default odus password and
# offer (NOT force) a rotation on first interactive WSL shell. The
# previous iteration ran `chage -d 0 odus` to force PAM to demand a
# rotation on first SSH login -- great for security on a bare-metal
# flash, terrible for the CI use case where a job flashes the image
# and immediately tries to ssh in with `odus:odus.321` or a baked key:
# PAM's account-management phase rejects the session with "password
# change required, no TTY available" and the job dies with no shell.
#
# New behaviour:
#
#   * No `chage -d 0`. The default password just works. SSH password
#     auth, SSH key auth, sftp / scp, non-TTY sessions all succeed.
#   * /etc/nosi/default-password-active gets touched so consumers can
#     tell the system is on the baked credential. The motd renderer
#     (step 99) keys off this file to print a prominent "rotate the
#     default password" warning at every interactive login until the
#     operator rotates and removes the marker.
#   * The WSL profile.d snippet still offers an interactive `passwd`
#     prompt on first non-root interactive shell. It is gated on TTY,
#     so a `wsl exec` style automated invocation never sees it.
#
# Operators who want the old force-rotate behaviour can run
# `sudo chage -d 0 odus` manually post-flash.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 29-rotate-password (mark default, do not force)"
nosi_require_root

# Hashed_passwd as written by the variant userdata templates' users: block.
DEFAULT_HASH='$6$nosiOpRator$MNNihj4cU2CANkmlcYthq7Fa.U2r5VwwJxtm1TlqmznXizzkddi0sxKc3YnkgRpcvOLc2V7nOGpbp/tOyD5M81'

if ! getent passwd odus >/dev/null 2>&1; then
    nosi_warn "odus account missing; skipping (apply.sh ran on a non-baked host?)"
    exit 0
fi

current_hash=$(getent shadow odus 2>/dev/null | cut -d: -f2)
install -d -m 0755 /etc/nosi

if [ "$current_hash" != "$DEFAULT_HASH" ]; then
    # Operator has already rotated; clear the marker if a previous run
    # left it behind so the motd warning stops nagging.
    nosi_info "odus password already rotated; clearing default-password marker"
    rm -f /etc/nosi/default-password-active
else
    nosi_info "odus password is still the baked default; touching marker"
    touch /etc/nosi/default-password-active
fi

# Profile.d snippet: interactive-only `passwd` offer on WSL where there
# is no login(1) and PAM never runs. Skipped silently for non-TTY shells
# (i.e. `wsl exec`-style automation) so CI is not interrupted. Inert
# outside WSL (the bare-metal / Hetzner path lands on login(1) +
# PAM-aware shells where the warning in motd is sufficient).
nosi_write_if_changed \
'# Managed by nosi/provision/steps/29-rotate-password.sh
# WSL bypasses login(1) entirely. Offer (not force) a passwd rotation
# the first interactive shell sees the marker. Skipped on non-TTY
# shells so `wsl exec` style automation is not interrupted.

if [ -z "$PS1" ] || [ "$(id -u)" -eq 0 ] || [ ! -f /etc/nosi/default-password-active ]; then
    :
elif ! grep -qi microsoft /proc/version 2>/dev/null; then
    :
elif [ ! -t 0 ] || [ ! -t 1 ]; then
    :
else
    printf "\n\033[33m=== nosi: optionally rotate the default odus password ===\033[0m\n"
    printf "You are running with the baked default (odus.321).\n"
    printf "Set a new password now (or press Ctrl-D to skip and be reminded next login):\n\n"
    if passwd; then
        sudo rm -f /etc/nosi/default-password-active
        printf "\n\033[32m  password rotated; this prompt will not appear again\033[0m\n\n"
    else
        printf "\n\033[33m  skipped; the motd warning stays until you rotate\033[0m\n\n"
    fi
fi
' /etc/profile.d/nosi-rotate-password.sh 0644

nosi_info "step 29-rotate-password done"
