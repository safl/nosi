#!/usr/bin/env bash
# nosi/provision/steps/24-podman-setup.sh
#
# Podman ergonomics common to all shapes:
#
#   * /etc/containers/nodocker: suppresses podman-docker's "emulating
#     docker" banner so docker-compat invocations are quiet.
#   * Enable podman.socket: the system socket is what docker-compat
#     clients (docker SDK, compose) talk to. Lets `docker compose` etc.
#     work straight out of the bake without per-user setup.
#   * Assert a compose provider is on PATH: `podman compose` is only a
#     wrapper that looks up an external provider (podman-compose), so a
#     missing/renamed package would otherwise stay invisible until an
#     operator first runs `podman compose up`. Fail the bake here instead.
#
# The actual podman + podman-docker + crun + fuse-overlayfs +
# dbus-user-session + podman-compose packages are installed by cloud-init's
# `packages:` block (which still owns the apt/dnf install set); this step
# only wires the bits that need imperative commands.
#
# Idempotency: mkdir -p, touch, and systemctl enable are all no-ops on
# second run.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 24-podman-setup"
nosi_require_root

mkdir -p /etc/containers
touch /etc/containers/nodocker

systemctl enable podman.socket

# Compose provider must resolve. command -v (not `podman compose version`,
# which would try to reach podman's service) keeps this chroot-safe and
# matches the package-presence philosophy in step 06.
command -v podman-compose >/dev/null 2>&1 \
    || nosi_die "podman-compose not on PATH -- the compose provider for \`podman compose\` is missing (check the variant's packages: list)"

nosi_info "step 24-podman-setup done"
