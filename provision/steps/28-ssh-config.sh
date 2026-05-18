#!/usr/bin/env bash
# nosi/provision/steps/28-ssh-config.sh
#
# Drop /etc/ssh/sshd_config.d/00-nosi.conf with two settings:
#
#   PasswordAuthentication yes
#       Fedora's sshd_config ships with PasswordAuthentication=no by
#       default, which makes the baked `odus:odus.321` credentials
#       useless without an SSH key. Debian / Ubuntu cloud images ship
#       with it on; the drop-in is redundant there but harmless.
#   PermitRootLogin no
#       Defense in depth on top of step 22's `passwd -l root` (cloud-init
#       runcmd). If something rotates the root password later, sshd
#       still won't accept root logins.
#
# Idempotency: nosi_write_if_changed only touches mtime when the content
# differs.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 28-ssh-config"
nosi_require_root

install -d -m 0755 /etc/ssh/sshd_config.d
nosi_write_if_changed \
'# Managed by nosi/provision/steps/28-ssh-config.sh
PasswordAuthentication yes
PermitRootLogin no
' /etc/ssh/sshd_config.d/00-nosi.conf 0644

nosi_info "step 28-ssh-config done"
