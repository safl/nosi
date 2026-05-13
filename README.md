# nosi

[![build](https://github.com/safl/nosi/actions/workflows/build.yml/badge.svg)](https://github.com/safl/nosi/actions/workflows/build.yml)
[![docs](https://github.com/safl/nosi/actions/workflows/docs.yml/badge.svg)](https://safl.github.io/nosi/)
[![license](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![release](https://img.shields.io/badge/release-rolling-orange.svg)](#releasing)

**nosi** = **N**iche **O**perating **S**ystem **I**mages.
*(Pronounced "nosy" -- a nosy person can't help poking their nose in everywhere, and I can't help putting these images on every machine I touch.)*

Automated builds of operating-system images, pre-loaded with software fit
for systems development in C, Python, and Rust.

The output is a vanilla `.img.gz`. Flash it with `dd`, Balena Etcher, or
any tool that handles gzip-compressed disk images, and you have a
ready-to-SSH bare-metal dev box. The companion project
[bty](https://github.com/safl/bty) is one convenient flasher; it is not
required.

**Documentation: <https://safl.github.io/nosi/>** (sources in `docs/src/`)

## Scope

| Variant          | Distribution | Version    | Codename  | Arch    | Flavor   |
| ---------------- | ------------ | ---------- | --------- | ------- | -------- |
| `debian-sysdev`  | Debian       | 13         | trixie    | x86_64  | sysdev   |
| `ubuntu-sysdev`  | Ubuntu       | 26.04 LTS  | resolute  | x86_64  | sysdev   |
| `fedora-sysdev`  | Fedora       | 44         |           | x86_64  | sysdev   |
| `ubuntu-aidev`   | Ubuntu       | 26.04 LTS  | resolute  | x86_64  | aidev    |

`ubuntu-aidev` additionally publishes a WSL2 rootfs tarball at
`ghcr.io/<owner>/<repo>/ubuntu-aidev-wsl` (consumable by `wsl --import`)
derived from the same bake.

## Quick start

    make deps                          # install cijoe via pipx
    make build VARIANT=debian-sysdev   # build one variant
    make all                           # build every variant

Local builds need `qemu-system-x86_64` + KVM accessible. Building
`ubuntu-aidev` also needs `libguestfs-tools` (for the WSL post-bake
strip + tar-out).

## Releasing

Rolling, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` (immutable)
- `ghcr.io/<owner>/<repo>/<variant>:latest` (moves to most recent publish)

Publishes fire on push to `main`, weekly cron (Sunday 03:00 UTC), or
manual `workflow_dispatch`. PRs build but don't publish. bty consumes by
blob digest, not tag.
