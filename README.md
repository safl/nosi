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

Automated builds of opinionated operating-system images for niches the
stock cloud images don't quite hit. The output is a `.img.gz` (flashable
to bare metal with `dd` / Balena Etcher / any tool that handles
gzip-compressed disk images) and, for the `wsl` shape, additionally a
`.tar.gz` consumable by `wsl --import`. The companion project
[bty](https://github.com/safl/bty) is one convenient flasher; it is not
required.

**Documentation: <https://safl.github.io/nosi/>** (sources in `docs/src/`)

## Scope

Three shapes today: **`headless`** (C / C++ / Python / Rust systems
work on bare metal / VM / cloud), **`desktop`** (headless superset
plus a Hyprland tiling Wayland stack for personal laptop /
workstation use), and **`wsl`** (headless superset plus GUI dev
tools rendered through WSLg, published as a `.tar.gz` for `wsl
--import`). Optional tooling (agentic AI CLIs, GPU vendor stacks,
...) is post-flash via `nosi-addon` or via cijoe workflows under
`cijoe/workflows/`. A **`freebsd-<N>-headless`** scaffold landed in
2026-05 (Phase 1: bake + identity + baseline packages + kernel
source, no provision chain yet).

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

Local builds need `qemu-system-x86_64` + KVM accessible. The
`wsl`-shape post-bake step additionally needs `sudo` for `qemu-nbd`
attach + chroot tar-out -- any modern Linux host with the loadable
`nbd` kernel module fits the bill.

## Releasing

Rolling, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` (immutable)
- `ghcr.io/<owner>/<repo>/<variant>:latest` (moves to most recent publish)

Publishes fire on push to `main`, weekly cron (Sunday 03:00 UTC), or
manual `workflow_dispatch`. PRs build but don't publish. bty consumes by
blob digest, not tag.
