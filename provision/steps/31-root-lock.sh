#!/usr/bin/env bash
# nosi/provision/steps/31-root-lock.sh
#
# Lock root unconditionally. The only login channel on a nosi image is
# odus; root SSH is additionally blocked by step 28's PermitRootLogin no,
# and this step is the second leg of that defense in depth -- if the
# sshd drop-in ever gets clobbered, root still cannot log in because
# /etc/shadow's password field is `!` (no valid hash matches).
#
# Currently a no-op on top of the cloudinit-headless-*.user's `pw lock
# root` (FreeBSD) / cloud-init's default-root-locked behavior (Linux
# cloud images ship with root either disabled or password-locked), but
# the Phase 2 plan is to drop the runcmd / users: pieces from the .user
# files and have apply.sh own the root-locked state.
#
# Idempotent: usermod -L / pw lock are both no-ops when root is already
# locked. Runs late (after every other step has done its work as root)
# so root remains usable for the rest of apply.sh; this only affects
# what happens at next login.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 31-root-lock"
nosi_require_root

if [ "$NOSI_DISTRO" = "freebsd" ]; then
    pw lock root 2>/dev/null || true
    nosi_info "step 31-root-lock done (freebsd)"
    exit 0
fi

# usermod -L sets the password field to `!<existing-hash>`. On distros
# that ship root with no usable password (`*` or `!`), this is a no-op.
# On distros that boot with a usable root password (rare in cloud images
# but possible), this disables password login while leaving the account
# present for sudo / su.
usermod -L root

nosi_info "step 31-root-lock done ($NOSI_DISTRO)"
