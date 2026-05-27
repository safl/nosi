# Overview

`nosi` builds disk images for bringing up bare-metal systems for development
work. The output is a vanilla `.img.gz` flashable with any standard tool;
nothing about the image format ties it to a specific deployment workflow.

## Shapes

Every nosi variant is **the nosi flavor of `<upstream>`** -- the
opinionated layer nosi puts on top of a stock cloud image. The
suffix in the variant name describes the **shape** the system takes:
how it's deployed, what kind of hardware or environment it's for.
Distro + numerical version in a variant name are self-explanatory
(Ubuntu 24.04, Debian 13, ...); the shape is the nosi-specific bit
that needs an introduction.

Three shapes ship today:

- **`headless`** : C / C++ / Python / Rust systems work; server /
  VM / bare-metal-without-display use. Compilers, build tooling
  (meson / ninja / cmake / cargo), debuggers (gdb + gdb-dashboard,
  lldb), perf / strace / valgrind, user-space PCI prereqs (vfio
  plumbing, hugepages, IOMMU cmdline), containers (podman / buildah
  / skopeo), local virtualisation (qemu / OVMF), hardware inspection
  (dmidecode / lshw / nvme-cli / smartmontools), the helix / zellij
  / lazygit / yazi daily-driver layer, and a pipx-installed Python
  CLI set (uv, ruff, pyright, devbind).
- **`desktop`** : headless superset plus a Sway tiling Wayland
  compositor + tuigreet greeter + Firefox + audio (PipeWire +
  WirePlumber) + bluetooth + brightness + power-profiles-daemon. For
  personal laptop / workstation use.
- **`wsl`** : headless superset plus a curated set of GUI dev tools
  (meld, gitk, git-gui) that render through WSLg without a compositor
  inside the rootfs. wsl-shape variants publish a `.tar.gz`
  consumable by `wsl --import` (alongside an .img.gz side-effect of
  the bake pipeline).

Optional tooling collections that don't define a shape (agentic AI
CLIs, NVIDIA CUDA + NOKM + DOCA stack, AMD ROCm stack, MLNX_OFED,
...) are out-of-scope for the baked variants. The dividing line is
**reboots**:

- **No-reboot installs** ship as **add-ons** under `/opt/nosi/addons/`
  on the flashed image, launched via `nosi-addon` (fzf-based TUI
  that filters by shape / distro / version). Today:
  `agentic-cli` (Node + claude-code / codex / gemini-cli / opencode +
  LSPs + JetBrainsMono Nerd Font).
- **Multi-reboot installs** stay as **cijoe workflows** under
  `cijoe/workflows/setup_*.yaml`, run from a control box over SSH.
  cijoe's `wait_for_transport` step handles the reboots transparently.
  Today: `setup_cudadev.yaml` (NVIDIA stack), `setup_rocmdev.yaml`
  (AMD stack).

The intent: a flashable variant stays focused on **what kind of
system it is**; "what extras you want installed" is the operator's
call post-flash.

Each variant is a self-contained build keyed by
`<distro>-<version>-<shape>`. There is **no actual layered
inheritance** (no Yocto / Nix style composition); the word "shape"
describes a curated package list and configuration, nothing more. The
bare `*-base` variants (cloud-image-stock plus identity, no shape
layer) are still on the roadmap.

## Variants

The currently-published variants, their distros, baked tool versions,
default credentials, and pull/flash recipes live in the
[catalog](_generated/catalog.md). The catalog page is regenerated on
every docs build from the ORAS metadata layer each image publishes
to GHCR, so it reflects the bytes actually on disk rather than
hand-curated prose that can drift.

Variant names follow `<distro>-<version>-<shape>`, e.g.
`debian-13-headless`, `ubuntu-2604-wsl`, `freebsd-15-headless`. The
version-in-the-name lets multiple kernel / user-land releases of the
same distro coexist when their use cases call for it (for example,
`ubuntu-2404-headless` exists alongside `ubuntu-2604-headless`
because NVIDIA / AMD / Mellanox qualify their apt repos against 24.04
LTS while 26.04 LTS is the recency-leaning pick for non-vendor use).

`ubuntu-2604-wsl` publishes a sibling GHCR repo `<variant>-wsl` with
the WSL2 rootfs tarball alongside the regular `.img.gz`. Operators
import it via `wsl --import`; everything inside renders through
WSLg, so GUI tools work without a compositor in the rootfs.

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
6. For variants that declare a `[publish_wsl]` block (today:
   `ubuntu-2604-wsl`), `wsl_rootfs_publish` derives a WSL2 rootfs
   tarball from the same bake: attach the qcow2 via `qemu-nbd`, mount
   the detected ext4 rootfs partition, chroot in to apt-purge the
   kernel/grub/firmware/cloud-init/netplan/NM plumbing, `tar` the
   stripped rootfs out (`--xattrs --acls --numeric-owner`), and gzip
   + sha256-seal. No-op for variants without a `[publish_wsl]` block.

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
    cloudinit-<shape>-<distro>-<version>.user  # per-variant cloud-init user-data
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
