# Overview

`nosi` builds headless and desktop system images for bare metal and virtual
machines (qemu, WSL2), plus container images, pre-loaded with an opinionated
toolset for development work. The disk-image shapes ship as a vanilla
`.img.gz` flashable with any standard tool; nothing about the format ties an
image to a specific deployment workflow.

## Shapes

Every nosi variant is **the nosi flavor of `<upstream>`** -- the
opinionated layer nosi puts on top of a stock cloud image. The
suffix in the variant name describes the **shape** the system takes:
how it's deployed, what kind of hardware or environment it's for.
Distro + numerical version in a variant name are self-explanatory
(Ubuntu 24.04, Debian 13, ...); the shape is the nosi-specific bit
that needs an introduction.

Four shapes ship today. `headless` is the **base**; the other three
are **derived** from it (see [the layered model](#the-layered-model)):

- **`headless`** : the base. C / C++ / Python / Rust / Zig systems
  work; server / VM / bare-metal-without-display use. Compilers
  (gcc / clang / rustc / zig), build tooling (meson / ninja / cmake /
  cargo), language servers (clangd / pyright / rust-analyzer / zls),
  debuggers (gdb +
  gdb-dashboard, lldb), perf / strace / valgrind, user-space PCI
  prereqs (vfio plumbing, hugepages, IOMMU cmdline), containers
  (podman / buildah / skopeo), local virtualisation (qemu / OVMF),
  hardware inspection (dmidecode / lshw / nvme-cli / smartmontools),
  the helix / zellij / lazygit / yazi daily-driver layer, a
  pipx-installed Python CLI set (uv, ruff, pyright, devbind), and the
  cijoe orchestration tool (drives qemu-guest / test workflows).
- **`desktop`** : headless plus a Sway tiling Wayland compositor +
  tuigreet greeter + Firefox + GUI git tools (meld / gitk / git-gui) +
  audio (PipeWire + WirePlumber) + bluetooth + brightness +
  power-profiles-daemon. Bootable `.img.gz`. For personal laptop /
  workstation use.
- **`wsl`** : headless plus a curated set of GUI dev tools (meld,
  gitk, git-gui) that render through WSLg without a compositor in the
  rootfs, then the kernel / boot / cloud-init are stripped. Publishes
  a `.tar.gz` consumable by `wsl --import`.
- **`docker`** : the headless base (qemu + cijoe already in it),
  kernel / boot / cloud-init stripped and packaged as an OCI image via
  `docker import` -- so this shape is purely a packaging derivation, no
  extra tools. A CI bootstrap host: a Linux environment that launches
  qemu guests via cijoe (nested KVM on GitHub Actions when the job runs
  `--privileged` / passes `/dev/kvm`, or real device passthrough on
  bare metal), and a general dev base for a project's `make docker`.
  Used as a GHA job `container:` or pulled with docker.
- **`lxc`** : the headless base as an LXC **system** container
  (systemd as PID 1, unlike the single-process `docker` shape):
  kernel / firmware / cloud-init / NetworkManager stripped (the
  container shares the host kernel and the platform owns networking),
  validated under `systemd-nspawn`, packaged as a `.tar.zst` rootfs
  tarball. Drop into a Proxmox storage's `template/cache/` and
  `pct create`, or import into Incus / LXD.
- **`proxmox`** : the headless Debian base turned into a Proxmox VE
  host (PVE 9, no-subscription repo): the PVE kernel + stack baked in,
  daemons come up on first boot (web UI on `:8006`), a first-boot
  oneshot turns a blank second disk into `nvme-data` directory
  storage, and `nosi-proxmox-mkbridge` scaffolds the `vmbr0` bridge.
  Bootable `.img.gz`; the hypervisor inherits nosi's hardware support
  and IOMMU / vfio tuning.

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

(the-layered-model)=
### The layered model

Per distro+version, the `headless` variant is the **base**: it bakes
once from the stock cloud image, running the full
`apply.sh <variant>` provision chain. The `desktop` / `wsl` / `docker`
variants are **derived** from that baked rootfs rather than re-baked:
`derive_publish` copies the base qcow2, chroots in, runs
`apply.sh <derived-variant> --shape-only` (which re-stamps identity
and runs only the shape's step, installing the shape's packages +
config), optionally strips kernel / boot / cloud-init, and repackages
(bootable `.img.gz` for desktop, `.tar.gz` for wsl, OCI image for
docker).

The shared infrastructure (the base provision steps: release stamp,
tool installs, ssh, daemon-prune, ...) therefore runs **once** per
base, not once per shape. `apply.sh` stays the single definition of a
variant: each step is idempotent, so an operator on a vanilla VM runs
the full `apply.sh <variant>` and gets the complete result, while the
CI derive runs it `--shape-only` on the already-provisioned base and
only the delta executes.

The bare `*-base` variants (cloud-image-stock plus identity, no shape
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

Each shape publishes to its own GHCR repo named for the variant.
`ubuntu-2604-wsl` is a WSL2 rootfs `.tar.gz` (oras artifact;
`wsl --import` it, GUI tools render through WSLg). `ubuntu-2604-docker`
is a real OCI image (`docker pull` it or use it as a GHA `container:`).
Keeping each shape in its own repo keeps bty's flashable catalog
scoped to the real disk images (headless `.img.gz`, desktop `.img.gz`).

Windows is on the roadmap; FreeBSD (`freebsd-14/15-headless`) runs the
same shared provision chain as the Linux variants, delivered to nuageinit
as a base64 tarball (it has no `write_files`). It is a C/C++/Python base
(base clang/lldb + cmake/meson/ninja/python, plus gdb/ruff/uv/lazygit/
cijoe) with kernel source in `/usr/src`; Rust/Zig are opt-in via `pkg
install` to keep llvm out of the image.

Per-variant use cases live in the `org.opencontainers.image.description`
ORAS annotation on each published artifact and are surfaced on the
[catalog](_generated/catalog.md). That keeps the docs and the
shippable artifact aligned: when a variant is added, retired, or its
purpose shifts, the description on the artifact is updated and the
docs follow on the next regen. (The `docker` shape, an OCI image
without that metadata layer, is documented here in prose rather than
auto-rendered into the catalog.)

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
6. For a base that declares `[[...derive]]` entries (today:
   `ubuntu-2604-headless` -> wsl + docker; `fedora-44-headless` ->
   desktop), `derive_publish` builds each derived shape from the same
   bake without re-baking: copy the qcow2, attach via `qemu-nbd`,
   mount the detected ext4 rootfs, bind-mount /dev /proc /sys /run +
   the host resolv.conf, chroot in to run
   `apply.sh <derived-variant> --shape-only` (installs the shape's
   packages + config), optionally apt-purge the
   kernel/grub/firmware/cloud-init/netplan/NM plumbing, then repackage:
   bootable `.img.gz` (desktop), `tar`-ed + gzipped rootfs (wsl), or
   `docker import` into an OCI image (docker). No-op for a base with
   no `derive` entries.

Layout mirrors `safl/bty`'s internal `cijoe/` + `bty-media/` pattern.

## Repository layout

```
Makefile                            # build / deps / all / clean / docs-*
cijoe/
  configs/<variant>.toml            # cloud image URL, qemu guest, publish paths
  tasks/build.yaml                  # cijoe workflow
  scripts/diskimage_build.py        # download -> resize -> seed -> boot -> snapshot
  scripts/img_gz_publish.py         # qcow2 -> raw -> .img.gz + sha256
  scripts/derive_publish.py         # base qcow2 -> chroot --shape-only -> .img.gz / .tar.gz / OCI
variants.yml                        # per-variant metadata (shape, flashable, description)
tools/gen_catalog.py                # variants.yml -> bty-compatible catalog.toml
nosi-media/
  auxiliary/
    cloudinit-metadata.meta             # shared NoCloud meta-data
    cloudinit-headless-<distro>-<version>.user  # base cloud-init (derived shapes need none)
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
