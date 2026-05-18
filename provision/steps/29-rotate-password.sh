#!/usr/bin/env bash
# nosi/provision/steps/29-rotate-password.sh
#
# Force the baked default password to expire so the first interactive
# login has to set a fresh one. Belt and suspenders, because the two
# login paths nosi cares about treat password aging differently:
#
#   * login(1) + sshd-via-PAM (bare metal, Hetzner VM, anywhere SSH
#     password auth is on): `chage -d 0 odus` makes /etc/shadow's
#     last-change column zero, which PAM reads as "expired"; PAM's
#     chauthtok exchange then runs before the shell is granted. A
#     non-TTY connection (sftp, scp) fails closed, which is the
#     intended behaviour: rotate first, automate second.
#   * WSL2: `wsl -d <name>` spawns bash directly as the configured
#     default user without going through login(1) or PAM auth, so
#     password aging is never consulted. The /etc/profile.d snippet
#     below covers that gap by detecting the marker file and running
#     `passwd` from the interactive shell itself. Gated on /proc/version
#     containing microsoft so the snippet is inert on the flashable
#     bare-metal target (where chage already handles it).
#
# Skip when re-running on a system that has already rotated: comparing
# /etc/shadow's hash to the known baked default tells us whether odus
# is still on `odus.321`. A Hetzner-VM operator's existing password
# does not get clobbered.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 29-rotate-password"
nosi_require_root

# Hashed_passwd as written by the flavor templates' users: block.
DEFAULT_HASH='$6$nosiOpRator$MNNihj4cU2CANkmlcYthq7Fa.U2r5VwwJxtm1TlqmznXizzkddi0sxKc3YnkgRpcvOLc2V7nOGpbp/tOyD5M81'

if ! getent passwd odus >/dev/null 2>&1; then
    nosi_warn "odus account missing; skipping (apply.sh ran on a non-baked host?)"
    exit 0
fi

current_hash=$(getent shadow odus 2>/dev/null | cut -d: -f2)
if [ "$current_hash" != "$DEFAULT_HASH" ]; then
    nosi_info "odus password already rotated; skipping"
    # Also clear the marker if a previous run left it behind.
    rm -f /etc/nosi/default-password-active
    exit 0
fi

# Mark the password expired so login(1) + sshd-via-PAM force a change.
chage -d 0 odus

# Drop the marker file the profile.d snippet keys off.
install -d -m 0755 /etc/nosi
touch /etc/nosi/default-password-active

# Profile.d snippet for the WSL path. Inert outside WSL (login already
# handles it via chage above).
nosi_write_if_changed \
'# Managed by nosi/provision/steps/29-rotate-password.sh
# WSL bypasses login(1) so password expiry never gates the session.
# Prompt for `passwd` on the first interactive shell when the marker
# file is present.

if [ -z "$PS1" ] || [ "$(id -u)" -eq 0 ] || [ ! -f /etc/nosi/default-password-active ]; then
    :
elif ! grep -qi microsoft /proc/version 2>/dev/null; then
    :
elif [ ! -t 0 ] || [ ! -t 1 ]; then
    :
else
    printf "\n\033[33m=== nosi: rotate the default odus password ===\033[0m\n"
    printf "You are running with the baked default (odus.321).\n"
    printf "Set a new password now:\n\n"
    if passwd; then
        sudo rm -f /etc/nosi/default-password-active
        printf "\n\033[32m  password rotated; this prompt will not appear again\033[0m\n\n"
    else
        printf "\n\033[31m  rotation declined; you will be prompted again on next login\033[0m\n\n"
    fi
fi
' /etc/profile.d/nosi-rotate-password.sh 0644

nosi_info "step 29-rotate-password done"
