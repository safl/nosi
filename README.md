<p align="center">
  <img src="docs/src/_static/nosi.png" alt="nosi" width="360">
</p>

# nosi

[![build](https://github.com/safl/nosi/actions/workflows/build.yml/badge.svg)](https://github.com/safl/nosi/actions/workflows/build.yml)
[![docs](https://github.com/safl/nosi/actions/workflows/docs.yml/badge.svg)](https://safl.github.io/nosi/)
[![license](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![release](https://img.shields.io/badge/release-rolling-orange.svg)](#releasing)

**nosi** = **N**iche **O**perating **S**ystem **I**mages.
*(Pronounced "nosy" -- a nosy person can't help poking their nose in everywhere, and I can't help putting these images on every machine I touch.)*

Automated builds of headless and desktop system images for bare metal and
virtual machines (qemu, WSL2, Proxmox), plus container images (OCI and
LXC), pre-loaded with an opinionated toolset for systems-development work
in C, C++, Python, Rust, and Zig.

The output is a `.img.gz` (flashable to bare metal with `dd` / Balena
Etcher / any tool that handles gzip-compressed disk images), for the `wsl`
shape a `.tar.gz` consumable by `wsl --import`, for the `docker` shape an
OCI image pullable with docker, and for the `lxc` shape a `.tar.zst`
system-container template for Proxmox CT / Incus. The companion project
[bty](https://github.com/safl/bty) is one convenient flasher; it is not
required.

**Documentation: <https://safl.github.io/nosi/>** (sources in `docs/src/`)

## Scope

Six shapes today, with **`headless`** as the base the others derive
from: **`headless`** (C / C++ / Python / Rust / Zig systems work on
bare metal / VM / cloud), **`desktop`** (headless plus a Sway tiling
Wayland stack for personal laptop / workstation use), **`wsl`**
(headless plus GUI dev tools rendered through WSLg, published as a
`.tar.gz` for `wsl --import`), **`docker`** (the headless base
stripped and packaged as an OCI image, no extra tools since cijoe is
already in the base; a CI bootstrap host that launches qemu guests via
cijoe, or a dev base for a project's `make docker`), **`lxc`** (the
headless base as an LXC system-container template, a `.tar.zst` rootfs
for Proxmox CT / Incus), and **`proxmox`** (the headless Debian base
turned into a Proxmox VE host, bootable `.img.gz`). desktop / wsl /
docker / lxc / proxmox are built by deriving from the baked headless
rootfs rather than re-baking. Optional tooling (agentic AI CLIs, GPU vendor
stacks, ...) is post-flash via `nosi-addon` or via cijoe workflows
under `cijoe/workflows/`. **`freebsd-<N>-headless`** variants run the
same shared provision chain (delivered to FreeBSD's nuageinit as a
base64 tarball since it has no `write_files`); they are C/C++/Python
focused, with Rust/Zig opt-in via `pkg install` to keep llvm out.
**`rpios-13-{headless,desktop}`** target the Raspberry Pi 4 + 5 (arm64,
one image for both): since Raspberry Pi OS does not boot in a generic
QEMU `virt` machine, these are not QEMU-baked but customized in place --
the official image is loop-mounted and the same provision chain runs in
a chroot (`make build-rpi`) -- so the result keeps the Foundation
kernel / firmware / bootloader and flashes straight to SD/USB.

For the up-to-date list of variants, baked tool versions, default
credentials, pull/flash recipes, and full package inventories see the
**[catalog](https://safl.github.io/nosi/_generated/catalog.html)**. The
catalog is regenerated on every docs build from the ORAS metadata layer
each image publishes to GHCR, so it reflects the bytes actually on
disk rather than hand-curated prose that can drift.

## Quick start

    make deps                              # install cijoe via pipx
    make build VARIANT=debian-13-headless    # build one variant
    make all                               # build every variant

Local builds need `qemu-system-x86_64` + KVM accessible. Deriving the
desktop / wsl / docker shapes additionally needs `sudo` for `qemu-nbd`
attach + chroot (and `docker` for the docker shape) -- any modern Linux
host with the loadable `nbd` kernel module fits the bill.

The Raspberry Pi image is built differently -- `make build-rpi` -- by
loop-mounting the official Raspberry Pi OS image and running the
provision chain in a chroot. Run it on an arm64 host for a native chroot
(an x86 host additionally needs `binfmt` + `qemu-user-static`); it needs
`sudo` for `losetup` / `mount` / `chroot`.

## Releasing

Rolling, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` (immutable)
- `ghcr.io/<owner>/<repo>/<variant>:latest` (moves to most recent publish)

Publishes fire on push to `main`, weekly cron (Sunday 03:00 UTC), or
manual `workflow_dispatch`. PRs build but don't publish. bty consumes by
blob digest, not tag.
