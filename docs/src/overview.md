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

Two flavors ship today: `sysdev` (C / Python / Rust systems work) and
`aidev` (sysdev superset plus agentic-AI command-line tooling). The bare
`*-base` variants are still on the roadmap.

## Variants

| Variant          | Distribution | Version    | Codename  | Arch    | Flavor   |
| ---------------- | ------------ | ---------- | --------- | ------- | -------- |
| `debian-sysdev`  | Debian       | 13         | trixie    | x86_64  | sysdev   |
| `ubuntu-sysdev`  | Ubuntu       | 26.04 LTS  | resolute  | x86_64  | sysdev   |
| `fedora-sysdev`  | Fedora       | 44         |           | x86_64  | sysdev   |
| `ubuntu-aidev`   | Ubuntu       | 26.04 LTS  | resolute  | x86_64  | aidev    |

`ubuntu-aidev` is the first variant with two deployment targets from one
bake: the standard flashable `.img.gz` (`x86_64`) and a WSL2 rootfs
`.tar.gz` consumable by `wsl --import`. The WSL artifact is published to
a sibling GHCR repo named `<variant>-wsl`. See [](#aidev).

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
6. For variants that declare a `[publish_wsl]` block (today: just
   `ubuntu-aidev`), `wsl_rootfs_publish` derives a WSL2 rootfs tarball
   from the same bake: attach the qcow2 via `qemu-nbd`, mount the
   detected ext4 rootfs partition, chroot in to apt-purge the
   kernel/grub/firmware/cloud-init/netplan/NM plumbing, `tar` the
   stripped rootfs out (`--xattrs --acls --numeric-owner`), and gzip +
   sha256-seal. No-op for sysdev variants.

Layout mirrors `safl/bty`'s internal `cijoe/` + `bty-media/` pattern.

## Repository layout

```
Makefile                            # build / deps / all / clean / docs-*
cijoe/
  configs/<variant>.toml            # cloud image URL, qemu guest, publish paths
  tasks/build.yaml                  # cijoe workflow
  scripts/diskimage_build.py        # download -> resize -> seed -> boot -> snapshot
  scripts/img_gz_publish.py         # qcow2 -> raw -> .img.gz + sha256
  scripts/wsl_rootfs_publish.py     # qcow2 -> qemu-nbd + chroot strip -> .tar.gz
nosi-media/
  auxiliary/
    cloudinit-metadata.meta             # shared NoCloud meta-data
    cloudinit-<flavor>-<distro>.user    # per-variant cloud-init user-data
docs/
  src/                              # sphinx markdown sources (this tree)
  tooling/                          # nosi-docs package (pyproject + cli)
  Makefile                          # sphinx-build wrapper
.github/workflows/
  build.yml                         # matrix build + GHCR publish
  docs.yml                          # docs build + GitHub Pages deploy
```

## Building the docs

A small Python package (`nosi-docs`) lives under `docs/tooling/` and
ships three console scripts: `nosi-docs-build-html`, `nosi-docs-build-pdf`,
`nosi-docs-serve`. The top-level `Makefile` exposes them as:

```
make docs-deps          # pipx install ./docs/tooling
make docs-html          # nosi-docs-build-html -> docs/_build/html/
make docs-pdf           # nosi-docs-build-pdf  -> docs/_build/latex/nosi.pdf
make docs-serve         # live-rebuild on http://localhost:8000
make docs-clean         # remove docs/_build/
```

The PDF build needs a LaTeX distribution (`texlive` variants on Linux,
MacTeX + latexmk on macOS).
