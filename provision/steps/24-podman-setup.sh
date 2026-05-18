#!/usr/bin/env bash
# nosi/provision/steps/24-podman-setup.sh
#
# Podman ergonomics common to all flavors:
#
#   * /etc/containers/nodocker: suppresses podman-docker's "emulating
#     docker" banner so docker-compat invocations are quiet.
#   * Enable podman.socket: the system socket is what docker-compat
#     clients (docker SDK, compose) talk to. Lets `docker compose` etc.
#     work straight out of the bake without per-user setup.
#
# The actual podman + podman-docker + crun + fuse-overlayfs +
# dbus-user-session packages are installed by cloud-init's `packages:`
# block (which still owns the apt/dnf install set); this step only wires
# the bits that need imperative commands.
#
# Idempotency: mkdir -p, touch, and systemctl enable are all no-ops on
# second run.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 24-podman-setup"
nosi_require_root

mkdir -p /etc/containers
touch /etc/containers/nodocker

systemctl enable podman.socket

nosi_info "step 24-podman-setup done"
