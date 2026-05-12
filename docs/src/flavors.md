# Flavors

A **flavor** in nosi is an opinionated package selection + configuration
layered onto a stock distro cloud image. The variant name encodes which
distro and which flavor (`<distro>-<flavor>`).

There is no actual filesystem inheritance between flavors -- each variant
is a self-contained build that happens to share its conceptual ancestry
with siblings.

## `sysdev` -- C / Python / Rust systems work

The only flavor shipped today. The intent: a freshly flashed box you can
SSH into and start writing / building / debugging systems code without a
second package-manager round-trip.

### What's baked in

**Compilers and runtimes**

- C / C++: `clang`, `gcc`, `gcc-c++` (Fedora), `build-essential` (Debian/Ubuntu)
- Python: `python3`, `pipx`, `uv` (from Astral upstream, not the distro)
- Rust: `rustup` with stable toolchain (system-wide under `/usr/local/rustup`
  and `/usr/local/cargo`)

**Language servers and lint/format**

- C / C++: `clangd`, `clang-format`, `clang-tidy`
- Python: `ruff` (linter + formatter + LSP), `pyright` (type-check LSP)
- Rust: `rust-analyzer` via `rustup component add`, plus `rustfmt` and
  `clippy` from rustup's default profile

**Debug and memory tools**

- `gdb`, `valgrind`, `strace`, `lsof`

**Editor / terminal stack**

- `helix`, `zellij`, `btop`, `htop`

**Containers**

- `podman`, `buildah`, `skopeo`
- `podman-docker` provides `/usr/bin/docker` as a shim
- `podman.socket` enabled at build, `/var/run/docker.sock` symlinked
  via the package's tmpfiles.d snippet

**Local virtualisation**

- `qemu-system-x86`, `qemu-utils` (Debian/Ubuntu) / `qemu-system-x86-core`,
  `qemu-img` (Fedora)
- `ovmf` / `edk2-ovmf` for UEFI guest firmware

**Storage / hardware diagnostics**

- `dmidecode`, `hdparm`, `lshw`, `nvme-cli`, `pciutils`, `smartmontools`,
  `usbutils`

### Userspace PCI / KVM / containers

`sysdev` is set up so an unprivileged `odus` shell can do userspace-PCI
work and pass devices through to local VMs or containers without `sudo`:

- IOMMU is enabled at boot (`intel_iommu=on amd_iommu=on iommu=pt`).
- `vfio-pci` and `uio_pci_generic` are auto-loaded at boot.
- A udev rule hands `/dev/vfio/*` to the `kvm` group; `odus` is a member.
- `/dev/kvm` is in the `kvm` group by default; `odus` is a member.
- Hugepages are not reserved at build (depends on host RAM); allocate at
  runtime with the `hugepages` helper.

#### Flipping IOMMU on/off

```
nosi-pci-mode status      # show current mode + cmdline
nosi-pci-mode vfio        # IOMMU on, intended for vfio-pci binding
nosi-pci-mode uio         # IOMMU off, intended for uio_pci_generic
sudo reboot               # required for cmdline change to apply
```

Auto-detects `grubby` (Fedora) vs `update-grub` (Debian/Ubuntu).

#### Binding a device to a userspace driver

[`devbind`](https://pypi.org/project/devbind/) (xnvme/devbind) is the
canonical interface:

```
devbind --status                              # list PCI devices + driver
devbind --bind vfio-pci 0000:01:00.0          # bind to vfio
devbind --bind uio_pci_generic 0000:01:00.0   # bind to uio
devbind --bind nvme 0000:01:00.0              # rebind to native driver
```

#### Managing hugepages

[`hugepages`](https://pypi.org/project/hugepages/) (xnvme/hugepages) is
the canonical interface:

```
hugepages --show                              # current state
hugepages --reserve 512                       # reserve 512 x 2 MiB pages
hugepages --clear                             # release back to the pool
```

#### Passing a device into a guest or container

After binding to `vfio-pci`:

```
# qemu: pass PCIe device 01:00.0 into a guest
qemu-system-x86_64 -enable-kvm -m 4G \
    -device vfio-pci,host=01:00.0 ...

# podman: same device into a container
podman run --rm -it \
    --device=/dev/vfio/$(readlink /sys/bus/pci/devices/0000:01:00.0/iommu_group | xargs basename) \
    --device=/dev/vfio/vfio \
    --group-add keep-groups \
    <image>
```

### Login banner

Every login dumps a one-screen snapshot of host state, regenerated each
boot by `nosi-motd.service`:

```
  nosi sysdev   Debian GNU/Linux 13 (trixie)   Linux 6.12.x   x86_64

  hostname:  nosi-debian
  ip:        192.168.1.42 (enp0s3)
  iommu:     vfio (IOMMU on)
  hugepgs:   0 (use 'hugepages' to allocate)
  cpu:       Intel(R) Xeon(R) Silver 4310 CPU @ 2.10GHz x 24
  ram:       64 GiB
  nvme:      0

  Helpers:
    nosi-pci-mode {vfio|uio|status}   flip IOMMU on/off (reboot to apply)
    devbind                           bind/unbind PCI device to a driver
    hugepages                         inspect / reserve hugepages
```

### Background daemons (minimized)

Stock cloud images carry a bag of timers/services that wake periodically
to refresh `apt`/`dnf` indexes, firmware metadata, motd, man-db cache, fs
scrubbing, etc. On a dev-flashed bare-metal box they cause unexpected IO
and lock the package manager at random times. `sysdev` masks them:

- Debian/Ubuntu: `apt-daily*`, `apt-daily-upgrade*`, `fwupd-refresh*`,
  `motd-news*`, `man-db.*`, `e2scrub_*`. `unattended-upgrades` is purged
  outright.
- Fedora: `dnf-makecache*`, `fwupd-refresh*`, `man-db-cache-update*`,
  `mlocate-updatedb*`.

Re-enable any of these post-flash with
`sudo systemctl unmask <unit> && sudo systemctl enable --now <unit>`.

## Roadmap flavors

- `base` -- bare minimum: cloud-init + openssh-server, nothing
  opinionated. For operators who want to bring their own overlay.
- Others (TBD) -- separated by audience or workload, named for the
  niche they fit.
