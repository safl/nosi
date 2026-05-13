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
gzip-compressed disk images) and, for the `aidev` flavor, additionally a
`.tar.gz` consumable by `wsl --import`. The companion project
[bty](https://github.com/safl/bty) is one convenient flasher; it is not
required.

**Documentation: <https://safl.github.io/nosi/>** (sources in `docs/src/`)

## Scope

Two flavors today:

- **`sysdev`** -- C / Python / Rust systems work on bare metal. Tight
  package set with no Node runtime; headless-server-friendly. Built-in
  toolchains and editors (`clang`, `gcc`, `rustup` + `rust-analyzer`,
  `uv`, `helix`, `zellij`), shell flair (`rg`, `fd`, `fzf`, `lazygit`,
  `yazi`, `git-delta` wired as the system-wide git pager, `direnv`,
  `just`, `gh`, `shellcheck`), LSPs that round out helix coverage
  (`clangd`, `rust-analyzer`, `ruff`, `pyright`, `taplo`, `marksman`),
  hardware/storage inspection (`dmidecode`, `lshw`, `nvme-cli`,
  `pciutils`, `smartmontools`, `usbutils`), container stack (`podman`,
  `buildah`, `skopeo`, `podman-docker`), local QEMU (`qemu-system-x86`,
  `ovmf`), userspace-PCI plumbing (`vfio-pci`, `uio_pci_generic`, IOMMU
  helpers).
- **`aidev`** -- `sysdev` superset, plus Node and a curated set of
  agentic-AI CLIs (`claude`, `codex`, `gemini`, `opencode`, `pi`),
  Node-based LSPs (`bash-language-server`, `yaml-language-server`),
  distro RDMA userspace, and the JetBrainsMono Nerd Font. Ships as both
  a flashable `.img.gz` and a WSL2 rootfs `.tar.gz` derived from the
  same bake; the WSL tarball goes to a sibling GHCR repo named
  `<variant>-wsl`.

See [`docs/src/flavors.md`](docs/src/flavors.md) for the deep dive
(rationale per tool, system-wide config touchpoints, login banner).

### Variants

| Variant          | Distribution | Version    | Codename  | Arch    | Flavor   |
| ---------------- | ------------ | ---------- | --------- | ------- | -------- |
| `debian-sysdev`  | Debian       | 13         | trixie    | x86_64  | sysdev   |
| `ubuntu-sysdev`  | Ubuntu       | 26.04 LTS  | resolute  | x86_64  | sysdev   |
| `fedora-sysdev`  | Fedora       | 44         |           | x86_64  | sysdev   |
| `ubuntu-aidev`   | Ubuntu       | 26.04 LTS  | resolute  | x86_64  | aidev    |

## Quick start

    make deps                          # install cijoe via pipx
    make build VARIANT=debian-sysdev   # build one variant
    make all                           # build every variant

Local builds need `qemu-system-x86_64` + KVM accessible. The
`ubuntu-aidev` WSL post-bake step additionally needs `sudo` for
`qemu-nbd` attach + chroot tar-out -- any modern Linux host with the
loadable `nbd` kernel module fits the bill.

## Releasing

Rolling, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` (immutable)
- `ghcr.io/<owner>/<repo>/<variant>:latest` (moves to most recent publish)

Publishes fire on push to `main`, weekly cron (Sunday 03:00 UTC), or
manual `workflow_dispatch`. PRs build but don't publish. bty consumes by
blob digest, not tag.
