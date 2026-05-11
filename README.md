# csi

Automated builder for headless system images consumed by [bty](https://github.com/safl/bty).

## Scope

| Variant         | Distribution      | Arch    |
| --------------- | ----------------- | ------- |
| `debian-base`   | Debian 13 trixie  | x86_64  |
| `ubuntu-base`   | Ubuntu 24.04 LTS  | x86_64  |
| `fedora-base`   | Fedora 43         | x86_64  |

FreeBSD and Windows variants are planned. Appliance overlays will be stacked on
top of the bases.

## How it works

csi follows the same shape as
[jellyfin-kiosk-appliance-builder](https://github.com/safl/jellyfin-kiosk-appliance-builder).
Each variant pairs a small TOML config in `configs/` with a cloud-init
user-data file in `auxiliary/`. A [cijoe](https://github.com/refenv/cijoe)
task drives the build:

1. Downloads the upstream cloud image (Debian / Ubuntu / Fedora).
2. Resizes the boot disk so the package install fits.
3. Generates a NoCloud seed ISO from the variant's user-data + shared meta-data.
4. Boots QEMU with the seed; cloud-init installs the package list, drops in
   `uv`, enables `podman.socket`, wipes machine identity, and powers off.
5. Snapshots the baked image to `~/system_imaging/disk/csi-<variant>-x86_64.qcow2`
   with a SHA-256 sidecar.

The packaging step converts the qcow2 to `.raw.zst` for bty's catalog.

## Images ship anonymous

No user, no SSH key, no hostname is baked in at build time. The image
contains cloud-init with the NoCloud datasource, but the runtime seed
directory is wiped at the end of the build. bty (or whoever does the
flashing) is expected to write `/var/lib/cloud/seed/nocloud/{user-data,meta-data}`
at flash time, supplying per-target identity. Host SSH keys and machine-id
are stripped at build, regenerated per-instance on first boot.

## Quick start

    make deps                          # install cijoe via pipx
    make build VARIANT=debian-base     # build a variant
    make package VARIANT=debian-base   # convert qcow2 → .raw.zst + sha256
    make all                           # build every variant

Local builds need a host with `/dev/kvm` available and qemu + mkisofs
installed. CI runs inside `ghcr.io/refenv/cijoe-docker:latest`, which has
everything bundled.

## Releasing

Rolling, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` — immutable
- `ghcr.io/<owner>/<repo>/<variant>:latest` — moves to the most recent publish

A publish fires automatically on push to `main`, weekly cron (Sunday 03:00
UTC), or manual `workflow_dispatch`. PRs build but don't publish.

bty consumes by **blob digest**, not tag — the workflow's summary page prints
each per-build digest, and that digest is the canonical reference forever.

Consumers can flash directly without any registry client:

    curl -sL 'https://ghcr.io/v2/<owner>/<repo>/<variant>/blobs/sha256:<digest>' \
        | zstd -d \
        | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

## Layout

    Makefile                          # entry points: deps / build / package / all
    configs/
      debian-base.toml                # variant TOML — cloud image URL, qemu guest
      ubuntu-base.toml
      fedora-base.toml
    tasks/
      build.yaml                      # cijoe workflow
    scripts/
      diskimage_build.py              # cijoe task: download → resize → seed → boot → snapshot
      package.sh                      # qcow2 → .raw.zst + sha256
    auxiliary/
      cloudinit-metadata.meta         # shared NoCloud metadata
      cloudinit-debian-base.user      # per-variant cloud-init user-data
      cloudinit-ubuntu-base.user
      cloudinit-fedora-base.user
    .github/workflows/build.yml       # CI: matrix build + GHCR publish
