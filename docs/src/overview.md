# Overview

`nosi` builds disk images for bringing up bare-metal systems for development
work. The output is a vanilla `.img.gz` flashable with any standard tool;
nothing about the image format ties it to a specific deployment workflow.

## Flavors

Distro + version in a variant name are self-explanatory (Ubuntu 24.04,
Debian 13, etc.); the **flavor** is the nosi-specific bit that needs
an introduction. A flavor is an opinionated package selection layered
on top of the base cloud image, named for the work it's fit for.

Two flavors ship today:

- **`sysdev`** : C / C++ / Python / Rust systems work. Compilers,
  build tooling (meson / ninja / cmake / cargo), debuggers (gdb +
  gdb-dashboard, lldb), perf / strace / valgrind, user-space PCI
  prereqs (vfio plumbing, hugepages, IOMMU cmdline), containers
  (podman / buildah / skopeo), local virtualisation (qemu / OVMF),
  hardware inspection (dmidecode / lshw / nvme-cli / smartmontools),
  the helix / zellij / lazygit / yazi daily-driver layer, and a
  pipx-installed Python CLI set (uv, ruff, pyright, devbind). No Node
  runtime ([by design](https://github.com/safl/nosi/blob/main/provision/steps/41-npm-globals.sh) -- Node-based tools live in aidev).
- **`aidev`** : `sysdev` superset plus Node and a curated set of
  agentic-AI command-line tools (claude-code, codex, gemini-cli,
  opencode), JetBrainsMono Nerd Font, WSL configuration. Variants
  with this flavor additionally publish a WSL2 rootfs tarball
  consumable by `wsl --import`.

Each variant is a self-contained build keyed by
`<distro>-<version>-<flavor>`. There is **no actual layered
inheritance** (no Yocto / Nix style composition); the word "flavor"
describes a curated package list and configuration, nothing more. The
bare `*-base` variants (cloud-image-stock plus identity, no flavor
layer) are still on the roadmap.

## Variants

The currently-published variants, their distros, baked tool versions,
default credentials, and pull/flash recipes live in the
[catalog](_generated/catalog.md). The catalog page is regenerated on
every docs build from the ORAS metadata layer each image publishes
to GHCR, so it reflects the bytes actually on disk rather than
hand-curated prose that can drift.

Variant names follow `<distro>-<version>-<flavor>`, e.g.
`debian-13-sysdev`, `ubuntu-2604-aidev`, `freebsd-15-sysdev`. The
version-in-the-name is what lets multiple kernel / user-land releases
of the same distro coexist when their use cases call for it (see
"Why these distros" below).

`ubuntu-2604-aidev` is the first variant with two deployment targets
from one bake: the standard flashable `.img.gz` (`x86_64`) and a WSL2
rootfs `.tar.gz` consumable by `wsl --import`. The WSL artefact is
published to a sibling GHCR repo named `<variant>-wsl`.

Windows is on the roadmap; FreeBSD landed in 2026-05 as a Phase-1
scaffold (bake + identity + baseline packages + kernel source, no
provision chain yet).

Per-variant use cases live in the `org.opencontainers.image.description`
ORAS annotation on each published artefact and are surfaced on the
[catalog](_generated/catalog.md). That keeps the docs and the
shippable artefact aligned: when a variant is added, retired, or its
purpose shifts, the description on the artefact is updated and the
docs follow on the next regen.

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
   `ubuntu-2604-aidev`), `wsl_rootfs_publish` derives a WSL2 rootfs tarball
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
