# nosi

Automated builds of **Niche Operating System Images**. Niche because
they ship pre-loaded with software fit for systems development in C and
Python, plus a handful of dev tools of a certain opinionated flavor
(`helix`, `zellij`, `btop`, `uv`, `podman` + `podman-docker`, ...).

The output is a vanilla disk image. Flash it with `dd`, Balena Etcher,
or any tool that handles `.img.gz`, and you have a ready-to-SSH
bare-metal dev box. The companion project
[bty](https://github.com/safl/bty) is a convenient way to flash these
images onto systems in different ways; it is not required.

## Scope

| Variant          | Distribution | Version    | Codename  | Arch    | Flavor   |
| ---------------- | ------------ | ---------- | --------- | ------- | -------- |
| `debian-sysdev`  | Debian       | 13         | trixie    | x86_64  | sysdev   |
| `ubuntu-sysdev`  | Ubuntu       | 26.04 LTS  | resolute  | x86_64  | sysdev   |
| `fedora-sysdev`  | Fedora       | 44         |           | x86_64  | sysdev   |

The intent is **bare bases + opinionated flavors**, not actual layered
inheritance (no Yocto / Nix style composition). Each variant is a
self-contained build keyed by `<distro>-<flavor>`: the `sysdev` flavor
selects the package set fit for C / Python systems dev work; a future
`base` flavor would carry only the minimum to be SSH-reachable.

Today the only flavor shipped is `sysdev`. A bare `base` flavor and
other flavors (FreeBSD, Windows, …) are roadmap.

## How it works

Each variant pairs a TOML config in `cijoe/configs/` with a cloud-init
user-data file in `nosi-media/auxiliary/`. A cijoe task drives the build:

1. Downloads the upstream cloud image (Debian / Ubuntu / Fedora qcow2).
2. Resizes the boot disk so cloud-init has room to install our packages.
3. Generates a NoCloud seed ISO from the variant's user-data + shared
   meta-data.
4. Boots QEMU with the seed; cloud-init installs the package list, drops in
   `uv`, enables `podman.socket`, creates the `odus` operator account with
   default credentials, locks root, strips SSH host keys and machine-id,
   and powers off.
5. Compacts the baked qcow2 and gzip-publishes it as a dd-able `.img.gz`
   with a SHA-256 sidecar.

Layout, cijoe scripts, and cloud-init userdata structure all mirror
`safl/bty`'s internal `cijoe/` + `bty-media/` pattern, originally
modelled on `safl/jellyfin-kiosk-appliance-builder`.

## Default credentials

- Operator: `odus` / `odus` (passwordless sudo, shell `/bin/bash`)
- Root: locked
- SSH: password auth enabled on first boot
- **Rotate `odus`'s password before exposing the box to anything beyond a
  trusted network.**

SSH host keys are *not* baked: they're stripped at end of build, and sshd's
stock systemd preset regenerates a unique set on first boot. The
machine-id is wiped the same way, so every flashed instance has its own
identity.

If a downstream provisioner (bty, a kickstart pipeline, your own scripted
seeding, …) injects a fresh NoCloud seed at flash time, cloud-init runs
again on first boot of the flashed instance and applies it on top of these
defaults.

## Quick start

    make deps                          # install cijoe via pipx
    make build VARIANT=debian-sysdev     # build one variant
    make all                           # build every variant

Local builds need `qemu-system-x86_64` + KVM accessible. CI runs natively
on `ubuntu-24.04` runners with a udev rule that makes `/dev/kvm`
world-readable.

## Releasing

Rolling, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` (immutable)
- `ghcr.io/<owner>/<repo>/<variant>:latest` (moves to most recent publish)

Publishes fire on push to `main`, weekly cron (Sunday 03:00 UTC), or
manual `workflow_dispatch`. PRs build but don't publish.

Each per-build SHA-256 (the OCI blob digest) is printed on the workflow
summary page and lives forever. That's the canonical reference for any
consumer that wants reproducible flashing (bty does this by default; any
content-addressed tool can do the same).

Flashing directly, without any registry client:

    curl -sL 'https://ghcr.io/v2/<owner>/<repo>/<variant>/blobs/sha256:<digest>' \
        | gunzip -d \
        | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

## Layout

    Makefile                            # build / deps / all / clean
    cijoe/
      configs/
        debian-sysdev.toml                # cloud image URL, qemu guest, publish paths
        ubuntu-sysdev.toml
        fedora-sysdev.toml
      tasks/
        build.yaml                      # cijoe workflow: diskimage_build + img_gz_publish
      scripts/
        diskimage_build.py              # download → resize → seed → boot → snapshot
        img_gz_publish.py               # qcow2 → raw → .img.gz + sha256
    nosi-media/
      auxiliary/
        cloudinit-metadata.meta         # shared NoCloud meta-data
        cloudinit-sysdev-debian.user      # per-variant cloud-init user-data
        cloudinit-sysdev-ubuntu.user
        cloudinit-sysdev-fedora.user
    .github/workflows/build.yml         # matrix build + GHCR publish
