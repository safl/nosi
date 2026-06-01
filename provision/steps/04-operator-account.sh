#!/usr/bin/env bash
# nosi/provision/steps/04-operator-account.sh
#
# Own the operator account end-to-end from apply.sh, so `cloud-init` /
# `nuageinit` are reduced to delivering the provision tree + running
# apply.sh. This is the cornerstone of the "cloud-init is a delivery
# mechanism, not a configuration mechanism" tenet: what defines a nosi
# image lives here, not in the variant's .user file.
#
# Today's role is RE-ASSERTION (Phase 1): cloud-init still creates odus
# initially from the .user file's users: block, and this step normalises
# the state regardless of what cloud-init's per-impl quirks did:
#
#   * odus exists at uid 1000, gid 1000, with the canonical groups for
#     the platform (sudo + kvm on Linux; wheel + operator on FreeBSD).
#   * odus's password is the baked default hash (SHA-512 of "odus.321"
#     with salt "nosiOpRator"). Re-asserted via chpasswd / pw -h, so a
#     re-applied seed that locked or cleared the hash gets fixed up.
#   * The home dir is /home/odus, owned 1000:1000, mode 0750.
#
# Next iteration (Phase 2) is to also CREATE odus if missing, then
# remove the users: block from the .user files entirely; this step's
# code is shape-compatible with that change.
#
# Idempotent: every command no-ops when the state already matches.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 04-operator-account"
nosi_require_root

# SHA-512 of "odus.321" with salt "nosiOpRator". Verified end-to-end with
# `openssl passwd -6 -salt nosiOpRator odus.321`. Identical to the hash
# carried in every variant's cloudinit-headless-*.user file.
ODUS_HASH='$6$nosiOpRator$MNNihj4cU2CANkmlcYthq7Fa.U2r5VwwJxtm1TlqmznXizzkddi0sxKc3YnkgRpcvOLc2V7nOGpbp/tOyD5M81'

if [ "$NOSI_DISTRO" = "freebsd" ]; then
    # Create only if missing; usermod for state we know we own. The .user's
    # users: block is the current creator; this branch will start creating
    # in Phase 2 once the block is dropped.
    if ! pw user show odus >/dev/null 2>&1; then
        nosi_info "creating odus account (uid 1000, wheel + operator)"
        pw useradd odus -u 1000 -m -G wheel,operator -s /bin/sh \
            -c "nosi operator"
    fi

    # Re-assert password hash. `pw usermod -H 0` reads the pre-hashed
    # password from stdin (fd 0); -H takes a hash, -h takes a plaintext
    # password. Idempotent: rewrites the master.passwd entry to the same
    # value when already correct.
    printf '%s\n' "$ODUS_HASH" | pw usermod odus -H 0

    # Group membership: ensure wheel + operator (in case the account was
    # created without them).
    pw groupmod wheel -m odus 2>/dev/null || true
    pw groupmod operator -m odus 2>/dev/null || true

    # Home dir ownership.
    install -d -o odus -g odus -m 0750 /home/odus

    nosi_info "step 04-operator-account done (freebsd)"
    exit 0
fi

# ---- Linux ----------------------------------------------------------------

# Canonical secondary groups. `sudo` for /etc/sudoers.d (Debian / Ubuntu)
# or `wheel` (Fedora), but we keep `sudo` because nosi installs the sudo
# package on every Linux variant. `kvm` so the operator can drive
# /dev/kvm without sudo on bare-metal flashes (matches the headless
# operator profile).
groups="sudo"
getent group kvm >/dev/null 2>&1 && groups="$groups,kvm"

if ! getent passwd odus >/dev/null 2>&1; then
    nosi_info "creating odus account (uid 1000, groups: $groups)"
    useradd -m -u 1000 -U -G "$groups" -s /bin/bash -c "nosi operator" odus
fi

# Re-assert membership in those groups for an existing account (idempotent;
# usermod -aG only adds, never removes).
usermod -aG "$groups" odus

# Re-assert password hash via chpasswd -e (encrypted form). Same hash as
# every variant's .user; no-op when already set.
echo "odus:$ODUS_HASH" | chpasswd -e

install -d -o odus -g odus -m 0750 /home/odus

nosi_info "step 04-operator-account done ($NOSI_DISTRO)"
