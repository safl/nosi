#!/usr/bin/env bash
# nosi/provision/steps/07-odus-sudoers.sh
#
# Ensure odus has a passwordless-sudo drop-in regardless of which
# cloud-init implementation processed the variant's .user file.
#
# Why a dedicated step:
#
#   * On Linux distros cloud-init translates the variant userdata's
#     `users: [{ name: odus, sudo: "ALL=(ALL) NOPASSWD:ALL" }]` into a
#     /etc/sudoers.d/odus file. That is what the Linux smoketest's
#     `sudo -n true` assertion exercises and it has always worked.
#
#   * On FreeBSD nuageinit honors `users:`/`hashed_passwd` but NOT the
#     per-user `sudo:` field, so odus ends up in the `wheel` group with
#     no NOPASSWD authorisation -- `sudo -n true` then requires a
#     password and fails. The original fix wrote the drop-in via runcmd
#     lines in the .user file; nuageinit's runcmd parser tripped over
#     them and the bake hung for ~90 min before timing out. Doing it
#     here in apply.sh (real bash, full PATH, no nuageinit quoting
#     gymnastics) avoids that whole class of problem.
#
# Idempotent: nosi_write_if_changed only touches mtime when the content
# differs, so apply.sh re-runs are no-ops. The drop-in path differs
# between distros -- /etc/sudoers.d on Linux, /usr/local/etc/sudoers.d
# on FreeBSD (sudo is /usr/local/sbin/sudo from the pkg there) -- so
# branch on $NOSI_DISTRO. chmod 0440 matches sudo's required mode
# (sudoers visudo refuses to load files with looser perms).

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 07-odus-sudoers"
nosi_require_root

if ! getent passwd odus >/dev/null 2>&1 \
    && ! pw user show odus >/dev/null 2>&1; then
    nosi_warn "odus account missing; skipping (apply.sh ran on a non-baked host?)"
    exit 0
fi

if [ "$NOSI_DISTRO" = "freebsd" ]; then
    sudoers_dir=/usr/local/etc/sudoers.d
else
    sudoers_dir=/etc/sudoers.d
fi

install -d -m 0755 "$sudoers_dir"
nosi_write_if_changed \
'# Managed by nosi/provision/steps/07-odus-sudoers.sh
odus ALL=(ALL) NOPASSWD: ALL
' "$sudoers_dir/odus" 0440

nosi_info "step 07-odus-sudoers done ($NOSI_DISTRO: $sudoers_dir/odus)"
