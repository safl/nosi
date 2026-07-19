# Nic(h)e Operating System Images

```{only} html
[![build](https://github.com/safl/nosi/actions/workflows/build.yml/badge.svg)](https://github.com/safl/nosi/actions/workflows/build.yml)
[![license](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](https://github.com/safl/nosi/blob/main/LICENSE)
[![release](https://img.shields.io/badge/release-rolling-orange.svg)](release.md)
```

Automated, rolling builds of headless and desktop system images for bare metal
(x86_64, Raspberry Pi 4/5) and virtual machines (QEMU, WSL2, Proxmox), plus
container images (OCI, LXC),
pre-loaded with an opinionated toolset for systems-development work in C, C++,
Python, Rust, and Zig. Flash the `.img.gz` with `dd` (or any tool that handles
gzip-compressed disk images) and you have a ready-to-SSH dev box. The companion
project [bty](https://github.com/safl/bty) is one convenient flasher; it is not
required.

```{toctree}
:maxdepth: 2
:caption: Get started

overview
quickstart
desktop
kexec
```

```{toctree}
:maxdepth: 2
:caption: Catalog

catalog/index
```

```{toctree}
:maxdepth: 2
:caption: Reference

credentials
release
related
```
