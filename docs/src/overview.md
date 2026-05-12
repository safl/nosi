# Overview

`nosi` builds disk images for bringing up bare-metal systems for development
work. The output is a vanilla `.img.gz` flashable with any standard tool;
nothing about the image format ties it to a specific deployment workflow.

## Bare bases + opinionated flavors

The intended structure is **bare bases + flavors**:

- A **base** is a minimal distro-stock image with just enough to be SSH-
  reachable.
- A **flavor** is an opinionated package selection layered on top, named
  for the work it's fit for (`sysdev` for C / Python / Rust systems work,
  future flavors for other niches).

Each variant is a self-contained build keyed by `<distro>-<flavor>`. There
is **no actual layered inheritance** (no Yocto / Nix style composition);
the word "flavor" describes a curated package list and configuration,
nothing more.

Today only the `sysdev` flavor ships. The bare `*-base` variants and other
flavors are on the roadmap.

## Variants

| Variant          | Distribution | Version    | Codename  | Arch    | Flavor   |
| ---------------- | ------------ | ---------- | --------- | ------- | -------- |
| `debian-sysdev`  | Debian       | 13         | trixie    | x86_64  | sysdev   |
| `ubuntu-sysdev`  | Ubuntu       | 26.04 LTS  | resolute  | x86_64  | sysdev   |
| `fedora-sysdev`  | Fedora       | 44         |           | x86_64  | sysdev   |

FreeBSD and Windows variants are planned.

## Build pipeline

Each variant pairs a TOML config under `cijoe/configs/` with a cloud-init
user-data file under `nosi-media/auxiliary/`. A
[cijoe](https://github.com/refenv/cijoe) task drives the build:

1. Download the upstream cloud image (Debian / Ubuntu / Fedora qcow2).
2. Resize the boot disk so cloud-init has room to install our packages.
3. Generate a NoCloud seed ISO from the variant's user-data + shared
   meta-data.
4. Boot QEMU with the seed; cloud-init installs the package list, sets
   up the `odus` operator account, strips machine identity, powers off.
5. Compact the baked qcow2 and gzip-publish it as a dd-able `.img.gz`
   with a SHA-256 sidecar.

Layout mirrors `safl/bty`'s internal `cijoe/` + `bty-media/` pattern.
