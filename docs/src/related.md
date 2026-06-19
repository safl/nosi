# Related projects

## bty: the convenient flasher

[bty](https://github.com/safl/bty) writes pre-built system images onto
target disks, locally over USB or remotely over PXE. Its catalog binds
machines (by MAC) to images (by SHA-256), and the image-pull surface is
exactly the OCI blob digest nosi publishes. bty does not require nosi
(any compatible `.img.gz` works) and nosi does not require bty (any
flasher that handles gzip-compressed disk images works).

In a lab where nosi and bty are used together, the workflow is:

1. nosi CI publishes a new rolling image to GHCR.
2. The bty catalog references the image by blob digest.
3. bty re-flashes targets to that digest, locally or via PXE.

## xnvme: user space NVMe

The `headless` shape leans toward xNVMe-adjacent work: NVMe-CLI is
pre-installed, vfio-pci / uio_pci_generic / IOMMU are wired up so a
freshly-flashed box can immediately do user space NVMe development with
DPDK/SPDK and xNVMe/uPCIe.

The Python helpers shipped in `headless`:
[`devbind`](https://pypi.org/project/devbind/),
[`hugepages`](https://pypi.org/project/hugepages/), and
[`iommu`](https://pypi.org/project/iommu/), are the canonical
interface for changing PCI driver bindings, managing hugepages, and
switching the IOMMU substrate on nosi images. The first two are part of
the xNVMe ecosystem; `iommu` is a sibling tool with the same shape.

## cijoe: the build orchestrator

[cijoe](https://github.com/refenv/cijoe) drives the nosi build pipeline.
The layout mirrors `safl/bty`'s in-repo `cijoe/` + `bty-media/` pattern
(configs / scripts / tasks).

## Why "nosi"

**N**iche **O**perating **S**ystem **I**mages.

For the cheeky-minded, also legible as **N**ot **O**marchy **S**ystem
**I**mages: same urge to bake an opinionated dev setup into someone
else's distro, different crowd, different defaults.
