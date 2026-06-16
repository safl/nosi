<p align="center">
  <img src="docs/src/_static/nosi.png" alt="nosi" width="360">
</p>

# **N**ic(h)e **O**perating **S**ystem **I**mages

*(Pronounced "nosy", because I can't help putting these images on every machine I touch.)*

[![build](https://github.com/safl/nosi/actions/workflows/build.yml/badge.svg)](https://github.com/safl/nosi/actions/workflows/build.yml)
[![docs](https://github.com/safl/nosi/actions/workflows/docs.yml/badge.svg)](https://safl.dk/nosi)
[![license](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![release](https://img.shields.io/badge/release-rolling-orange.svg)](https://safl.dk/nosi/release.html)

Automated, rolling builds of headless and desktop system images for bare metal
(x86_64, Raspberry Pi 4/5) and virtual machines (QEMU, WSL2, Proxmox), plus
container images (OCI, LXC),
pre-loaded with an opinionated toolset for systems-development work in C, C++,
Python, Rust, and Zig. Flash the `.img.gz` with `dd` (or any tool that handles
gzip-compressed disk images) and you have a ready-to-SSH dev box. The companion
project [bty](https://github.com/safl/bty) is one convenient flasher; it is not
required.

## Documentation

The variant catalog, quick start, pull/flash recipes, default credentials, the
desktop shape, and the rolling-release model all live at:

### → <https://safl.dk/nosi>
