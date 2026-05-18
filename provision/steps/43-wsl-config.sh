#!/usr/bin/env bash
# nosi/provision/steps/43-wsl-config.sh
#
# aidev only. Write the WSL config files. Inert on the flashable bare-
# metal target; consumed by `wsl --import` on the WSL rootfs tarball
# derived from the same bake (wsl_rootfs_publish strips kernel / grub /
# firmware / cloud-init, but /etc/wsl.conf + /etc/wsl-distribution.conf
# come along).
#
#   /etc/wsl.conf
#       systemd=true so podman / agentic CLIs / NVIDIA stack behave
#       the same as on bare metal. default user odus. host-managed
#       hosts + resolv.conf.
#   /etc/wsl-distribution.conf
#       OOBE defaults so `wsl --install` lands a working odus account
#       (UID 1000, sudo + kvm + render + video).
#
# Idempotency: nosi_write_if_changed only touches mtime when content
# differs.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 43-wsl-config (flavor=${NOSI_FLAVOR:-?})"

if [ "${NOSI_FLAVOR:-}" != "aidev" ]; then
    nosi_info "non-aidev flavor; skipping"
    exit 0
fi

nosi_require_root

nosi_write_if_changed \
'[boot]
systemd=true

[user]
default=odus

[network]
generateHosts=true
generateResolvConf=true
hostname=nosi-aidev

[interop]
enabled=true
appendWindowsPath=true
' /etc/wsl.conf 0644

nosi_write_if_changed \
'[oobe]
defaultUid=1000
defaultName=odus
defaultGroups=sudo,kvm,render,video
' /etc/wsl-distribution.conf 0644

nosi_info "step 43-wsl-config done"
