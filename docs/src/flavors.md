# Flavors

A **flavor** in nosi is an opinionated package selection + configuration
layered onto a stock distro cloud image. The variant name encodes which
distro and which flavor (`<distro>-<flavor>`).

There is no actual filesystem inheritance between flavors -- each variant
is a self-contained build that happens to share its conceptual ancestry
with siblings.

## `sysdev` -- C / Python / Rust systems work

The intent: a freshly flashed box you can SSH into and start writing /
building / debugging systems code without a second package-manager
round-trip.

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

**Shell-side flair**

- `rg` (ripgrep), `fd` (fd-find), `fzf` -- helix's pickers and the rest
  of the terminal flow expect these
- `lazygit` -- TUI git client (installed from upstream release)
- `yazi` -- TUI file manager (installed from upstream release)
- `delta` -- syntax-highlighted diff/log/show pager, wired
  system-wide via `/etc/gitconfig` (override per-user in `~/.gitconfig`
  if you prefer the stock pager)
- `gh` -- GitHub CLI
- `just` -- task runner (`justfile` sister to `make`-as-task-runner)
- `direnv` -- per-directory env vars via `.envrc`; bash hook lives at
  `/etc/profile.d/nosi-direnv.sh`
- `shellcheck` -- bash linter (sysdev's substitute for the Node-based
  `bash-language-server` -- see the [aidev section](#aidev) for that)

**LSPs that round out helix coverage**

- `taplo` (TOML) and `marksman` (Markdown) -- both single-binary
  upstream installs, no runtime deps. They join `clangd`, `rust-analyzer`,
  `ruff`, and `pyright` (already part of the LSP stack above).
- Two more LSPs that depend on Node (`bash-language-server`,
  `yaml-language-server`) are intentionally not on `sysdev`; they ship
  with [`aidev`](#aidev) instead, alongside the Node runtime that
  flavor already needs for its agentic CLIs.

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

## `aidev` -- agentic-AI command-line tooling on top of `sysdev`

Conceptually a strict superset of `sysdev`: every package, every helper,
every daemon-prune carries over. On top of that, `aidev` lands the
agentic-AI CLIs operators reach for when working alongside model-driven
tooling, plus Node and a distro RDMA userspace.

Today only `ubuntu-aidev` ships -- Ubuntu is the lowest-friction base
for the vendor ecosystem an AI engineer is most likely to want to plug
in later (NVIDIA, Mellanox/DOCA, NIM containers, Triton/TensorRT, etc.).
The image itself is **GPU-vendor-neutral**: no driver is baked in. The
`x86_64` flashable artifact is a clean canvas across x86/nvidia,
x86/amd, and CPU-only deployments; the operator picks the vendor stack
post-flash.

### What's added on top of `sysdev`

**Node and npm**

- `nodejs`, `npm` from Ubuntu main (Node 22.x LTS). `npm`'s global
  prefix is repointed to `/usr/local` so the agentic CLIs and Node-based
  LSPs survive any Ubuntu npm reinstall. `sysdev` deliberately does
  not ship Node -- it stays a strict no-Node-runtime flavor.

**Agentic command-line tools**

- `claude` -- Anthropic Claude Code CLI (`@anthropic-ai/claude-code`)
- `codex` -- OpenAI Codex CLI (`@openai/codex`)
- `gemini` -- Google Gemini CLI (`@google/gemini-cli`)
- `opencode` -- sst/opencode (`opencode-ai`)
- `pi` -- pi.dev (curl-piped installer from `https://pi.dev/install.sh`)

The four npm-shipped CLIs install system-wide; `pi` lands wherever its
installer chooses (root path on bake).

**Node-based LSPs (aidev-only addition to the sysdev LSP stack)**

- `bash-language-server` -- bash LSP. `sysdev` covers shell linting
  via the lighter `shellcheck` distro package instead.
- `yaml-language-server` -- YAML LSP.

Both ride on the Node runtime aidev installs for the agentic CLIs.

**RDMA userspace (vendor-neutral)**

- `rdma-core`, `libibverbs1`, `libmlx5-1`, `ibverbs-utils`,
  `infiniband-diags`, `perftest`

Enough for ibverbs-capable apps to run end-to-end on any RDMA NIC the
operator drops in later. The kernel-tied side of an RDMA stack
(MLNX_OFED, kernel modules) stays opt-in.

**Operator account groups**

`odus` is added to `render` and `video` (on top of the `sysdev` defaults
of `sudo` and `kvm`), so DRM render-node access works without `sudo`
when an operator later installs an Intel/AMD/NVIDIA driver.

**JetBrainsMono Nerd Font**

Installed system-wide under `/usr/local/share/fonts/JetBrainsMonoNerdFont`
(from upstream's Nerd Fonts release). The font itself only matters for
rendering paths that exist on the box: X/Wayland apps (`wslg` on WSL2 is
the primary case here), the framebuffer console with an OTF-aware tool,
or X-forwarded SSH. For pure-SSH access set your *local* terminal's font
to a Nerd Font instead -- the font on the server doesn't matter to your
local renderer. `aidev` ships it because WSL is a primary target and
`wslg` is the most likely rendering path; `sysdev` does not.

### Two deployment targets, one bake

`ubuntu-aidev` is the first variant with two outputs derived from a
single QEMU bake:

| Target  | Artifact                                | Consumer                |
| ------- | --------------------------------------- | ----------------------- |
| x86_64  | `nosi-ubuntu-aidev-x86_64.img.gz`       | `dd`, bty, Etcher       |
| wsl     | `nosi-ubuntu-aidev-wsl.tar.gz`          | `wsl --import`          |

The WSL artifact is derived **after** the bake by `wsl_rootfs_publish`:
the baked qcow2 is copied, then `virt-customize` apt-purges the kernel,
bootloader, firmware, cloud-init, netplan, and NetworkManager, and
`virt-tar-out` streams the stripped rootfs to a `.tar` which is then
gzip + sha256-sealed.

Notable things that **survive** into the WSL rootfs: `qemu` + `ovmf`
(WSL2 exposes `/dev/kvm` via nested virt), the full container stack
(`podman`, `buildah`, `skopeo`, `podman-docker`), the agentic CLIs, the
RDMA userspace, and the standard `sysdev` development toolchain. The
two `/etc/wsl.conf` and `/etc/wsl-distribution.conf` files are written
unconditionally by cloud-init -- inert on the flashable artifact, used
on the WSL one (`systemd=true`, default user `odus`).

### Login banner

Same `nosi-motd.service` as `sysdev`, with the header swapped to
`nosi aidev`:

```
  nosi aidev   Ubuntu 26.04 LTS (resolute)   Linux 6.x.x   x86_64

  hostname:  nosi-aidev
  ip:        192.168.1.42 (eth0)
  iommu:     vfio (IOMMU on)
  hugepgs:   0 (use 'hugepages' to allocate)
  cpu:       Intel(R) Xeon(R) ...
  ram:       64 GiB
  nvme:      0

  Agentic CLIs:  claude  codex  gemini  opencode  pi
  Helpers:
    nosi-pci-mode {vfio|uio|status}   flip IOMMU on/off (reboot to apply)
    devbind                           bind/unbind PCI device to a driver
    hugepages                         inspect / reserve hugepages
```

## Roadmap flavors

- `base` -- bare minimum: cloud-init + openssh-server, nothing
  opinionated. For operators who want to bring their own overlay.
- Others (TBD) -- separated by audience or workload, named for the
  niche they fit.
