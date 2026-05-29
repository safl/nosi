# Niche Operating System Images

```{only} html
[![build](https://github.com/safl/nosi/actions/workflows/build.yml/badge.svg)](https://github.com/safl/nosi/actions/workflows/build.yml)
[![license](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](https://github.com/safl/nosi/blob/main/LICENSE)
[![release](https://img.shields.io/badge/release-rolling-orange.svg)](release.md)
```

Automated builds of headless and desktop system images for bare metal and
virtual machines (qemu, WSL2), plus container images, pre-loaded with an
opinionated toolset for systems-development work in C, C++, Python, Rust,
and Zig.

Flash the resulting `.img.gz` with `dd`, Balena Etcher, or any tool that
handles gzip-compressed disk images, and you have a ready-to-SSH dev box.
The companion project [bty](https://github.com/safl/bty) is one convenient
flasher; it is not required.

```{toctree}
:maxdepth: 2
:caption: Get started

overview
quickstart
```

```{toctree}
:maxdepth: 2
:caption: Catalog

_generated/catalog
```

```{toctree}
:maxdepth: 2
:caption: Reference

credentials
release
related
```
