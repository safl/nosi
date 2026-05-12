# nosi

[![build](https://github.com/safl/nosi/actions/workflows/build.yml/badge.svg)](https://github.com/safl/nosi/actions/workflows/build.yml)
[![docs](https://github.com/safl/nosi/actions/workflows/docs.yml/badge.svg)](https://safl.github.io/nosi/)
[![license](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![release](https://img.shields.io/badge/release-rolling-orange.svg)](#releasing)

**nosi** = **N**iche **O**perating **S**ystem **I**mages.
*(Also accepted: **N**ot **O**marchy **S**ystem **I**mages, if you're feeling cheeky. Same urge to bake an opinionated dev setup into someone else's distro, different crowd.)*

Automated builds of operating-system images, pre-loaded with software fit
for systems development in C, Python, and Rust.

The output is a vanilla `.img.gz`. Flash it with `dd`, Balena Etcher, or
any tool that handles gzip-compressed disk images, and you have a
ready-to-SSH bare-metal dev box. The companion project
[bty](https://github.com/safl/bty) is one convenient flasher; it is not
required.

## Scope

| Variant          | Distribution | Version    | Codename  | Arch    | Flavor   |
| ---------------- | ------------ | ---------- | --------- | ------- | -------- |
| `debian-sysdev`  | Debian       | 13         | trixie    | x86_64  | sysdev   |
| `ubuntu-sysdev`  | Ubuntu       | 26.04 LTS  | resolute  | x86_64  | sysdev   |
| `fedora-sysdev`  | Fedora       | 44         |           | x86_64  | sysdev   |

The intent is **bare bases + opinionated flavors**, not actual layered
inheritance (no Yocto / Nix style composition). Each variant is a
self-contained build keyed by `<distro>-<flavor>`. Today only the
`sysdev` flavor ships; a bare `base` flavor and other flavors (FreeBSD,
Windows, ...) are roadmap.

## Quick start

    make deps                          # install cijoe via pipx
    make build VARIANT=debian-sysdev   # build one variant
    make all                           # build every variant

Local builds need `qemu-system-x86_64` + KVM accessible. CI runs natively
on `ubuntu-24.04` runners with a udev rule that makes `/dev/kvm`
world-readable.

## Documentation

Rendered at <https://safl.github.io/nosi/>. Sources under `docs/src/`:

- **[Overview](docs/src/overview.md)** -- bases + flavors, build pipeline.
- **[Quick start](docs/src/quickstart.md)** -- build locally, flash, pull from GHCR.
- **[Flavors / sysdev](docs/src/flavors.md)** -- what's in the C/Python/Rust
  toolset; userspace PCI, KVM, container passthrough; daemon-minimization;
  the login banner; the `nosi-pci-mode` / `devbind` / `hugepages` helpers.
- **[Default credentials](docs/src/credentials.md)** -- `odus` / `odus.321`,
  per-instance SSH host keys, flash-time seed override.
- **[Release model](docs/src/release.md)** -- rolling, GHCR via ORAS,
  pinning by blob digest.
- **[Related projects](docs/src/related.md)** -- bty, xnvme, cijoe.

Build the docs:

    make docs-deps                     # one-time
    make docs-html                     # output in docs/_build/html/
    make docs-serve                    # live-rebuild on http://127.0.0.1:8000

## Releasing

Rolling, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` (immutable)
- `ghcr.io/<owner>/<repo>/<variant>:latest` (moves to most recent publish)

Publishes fire on push to `main`, weekly cron (Sunday 03:00 UTC), or
manual `workflow_dispatch`. PRs build but don't publish. bty consumes by
blob digest, not tag. See [docs/src/release.md](docs/src/release.md).

## Layout

    Makefile                            # build / deps / all / clean / docs-*
    cijoe/
      configs/<variant>.toml            # cloud image URL, qemu guest, publish paths
      tasks/build.yaml                  # cijoe workflow
      scripts/diskimage_build.py        # download → resize → seed → boot → snapshot
      scripts/img_gz_publish.py         # qcow2 → raw → .img.gz + sha256
    nosi-media/
      auxiliary/
        cloudinit-metadata.meta         # shared NoCloud meta-data
        cloudinit-sysdev-<distro>.user  # per-variant cloud-init user-data
    docs/
      src/                              # sphinx markdown sources
      Makefile                          # sphinx-build wrapper
    .github/workflows/build.yml         # matrix build + GHCR publish
