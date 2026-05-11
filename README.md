# csi

Automated builder for headless system images consumed by [bty](https://github.com/safl/bty).
Mirrors the structure of bty's own `cijoe/` + `bty-media/` layout and
`jellyfin-kiosk-appliance-builder`.

## Scope

| Variant         | Distribution      | Arch    |
| --------------- | ----------------- | ------- |
| `debian-base`   | Debian 13 trixie  | x86_64  |
| `ubuntu-base`   | Ubuntu 24.04 LTS  | x86_64  |
| `fedora-base`   | Fedora 43         | x86_64  |

FreeBSD and Windows variants are planned. Appliance overlays will stack on
top of the bases.

## How it works

Each variant pairs a TOML config in `cijoe/configs/` with a cloud-init
user-data file in `csi-media/auxiliary/`. A cijoe task drives the build:

1. Downloads the upstream cloud image (Debian / Ubuntu / Fedora qcow2).
2. Resizes the boot disk so cloud-init has room to install our packages.
3. Generates a NoCloud seed ISO from the variant's user-data + shared
   meta-data.
4. Boots QEMU with the seed; cloud-init installs the package list, drops in
   `uv`, enables `podman.socket`, creates the `odus` operator account
   (PiKVM-style default credentials), locks root, strips SSH host keys and
   machine-id, and powers off.
5. Compacts the baked qcow2 and gzip-publishes it as a dd-able `.img.gz`
   with a SHA-256 sidecar for bty's catalog.

## Default credentials

Same model as PiKVM / Raspberry Pi OS:

- Operator: `odus` / `odus` (passwordless sudo, shell `/bin/bash`)
- Root: locked
- SSH: password auth enabled on first boot
- **Rotate `odus`'s password before exposing the appliance to anything
  beyond a trusted network.**

SSH host keys are *not* baked: they're stripped at end of build, and
sshd's stock systemd preset regenerates a unique set on first boot. The
machine-id is wiped the same way.

If bty injects a fresh NoCloud seed at flash time (e.g. with a different
user / SSH key), cloud-init runs again on first boot of the flashed
instance and applies it on top of these defaults.

## Quick start

    make deps                          # install cijoe via pipx
    make build VARIANT=debian-base     # build one variant
    make all                           # build every variant

Local builds need `qemu-system-x86_64` + KVM accessible. CI runs natively
on `ubuntu-24.04` runners with a udev rule that makes `/dev/kvm` world-
readable; pattern lifted from bty's release workflow.

## Releasing

Rolling, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` — immutable
- `ghcr.io/<owner>/<repo>/<variant>:latest` — moves to most recent publish

Publishes fire on push to `main`, weekly cron (Sunday 03:00 UTC), or
manual `workflow_dispatch`. PRs build but don't publish.

bty consumes by **blob digest**, not tag; each per-build digest is printed
on the workflow summary page and lives forever.

Consumers flash directly without any registry client:

    curl -sL 'https://ghcr.io/v2/<owner>/<repo>/<variant>/blobs/sha256:<digest>' \
        | gunzip -d \
        | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

## Layout

    Makefile                            # build / deps / all / clean
    cijoe/
      configs/
        debian-base.toml                # cloud image URL, qemu guest, publish paths
        ubuntu-base.toml
        fedora-base.toml
      tasks/
        build.yaml                      # cijoe workflow: diskimage_build + img_gz_publish
      scripts/
        diskimage_build.py              # download → resize → seed → boot → snapshot
        img_gz_publish.py               # qcow2 → raw → .img.gz + sha256
    csi-media/
      auxiliary/
        cloudinit-metadata.meta         # shared NoCloud meta-data
        cloudinit-base-debian.user      # per-variant cloud-init user-data
        cloudinit-base-ubuntu.user
        cloudinit-base-fedora.user
    .github/workflows/build.yml         # matrix build + GHCR publish
