# nosi provision

System tweaks and toolchain installs that turn a fresh Debian / Ubuntu /
Fedora / FreeBSD cloud-init bake (or a fresh Hetzner VM, or a WSL2 import)
into a nosi-parity machine.

Each script under `steps/` is standalone, idempotent, and cross-distro
where the work is genuinely the same (DKMS, modprobe.d, systemd units,
profile.d snippets); per-distro otherwise. `apply.sh <variant>` runs the
whole chain in order. `lib/common.sh` provides distro detection
(`NOSI_DISTRO` one of debian/ubuntu/fedora/freebsd, `NOSI_PKGMGR` one of
apt/dnf/pkg), package-manager wrappers, logging, and an idempotency helper
that skips writing files whose content has not changed. See **FreeBSD**
below for how the chain runs there.

```
provision/
├── apply.sh              # entry point: apply.sh <variant>
├── lib/common.sh         # distro detect, logging, helpers
└── steps/
    ├── 05-nosi-release.sh          # FIRST: /etc/nosi-release with build identity
    ├── 06-package-presence.sh      # pre-flight: cloud-init's packages: actually landed
    ├── 08-network-dhcp.sh          # NIC-agnostic DHCP (no datasource on bare metal)
    ├── 09-growroot.sh              # grow rootfs to fill the disk on first boot
    ├── 10-r8125-dkms.sh
    ├── 12-gdb-dashboard.sh
    ├── 15-nouveau-blacklist.sh
    ├── 20-upstream-tools.sh        # uv, rust, helix, zellij, lazygit, yazi, taplo, marksman, oras
    ├── 21-shell-tools.sh           # fd, gitconfig, profile.d
    ├── 22-python-tools.sh          # ruff, pyright, devbind, hugepages, iommu
    ├── 23-userspace-pci.sh         # vfio-pci preload, /dev/vfio kvm group, memlock
    ├── 24-podman-setup.sh
    ├── 25-iommu-cmdline.sh         # intel_iommu / amd_iommu / iommu=pt
    ├── 26-daemon-prune.sh          # purge + mask headless-useless daemons
    ├── 27-snapd-disable.sh         # ubuntu-only: mask snapd, keep it re-enableable
    ├── 28-ssh-config.sh
    ├── 29-rotate-password.sh       # force first-login passwd change
    ├── 30-clock-from-http.sh
    ├── 32-firstboot-inventory.sh
    ├── 33-serial-console.sh        # console=ttyS0 / comconsole / Pi serial0 for IPMI SOL
    ├── 45-nosi-addons.sh           # install /opt/nosi/addons/ + /usr/local/bin/nosi-addon
    ├── 50-desktop-stack.sh         # desktop-shape only: greetd / sway / waybar configs
    ├── 98-metadata.sh              # /etc/nosi-metadata.json (tool versions, packages, identity)
    └── 99-motd.sh                  # LAST: login banner = "all earlier steps ran"
```

## Add-ons

Optional tooling collections that don't define a shape (agentic AI
CLIs, ...) ship as **add-ons** rather than baked variants. Each addon
is a one-shot, no-reboot installer under `/opt/nosi/addons/*.sh`
launched via `nosi-addon`. The launcher reads `/etc/nosi-release` on
the running system and only offers addons whose declared compatibility
matches the current shape / distro / version:

```
$ nosi-addon
[fzf menu of eligible addons]
> agentic-cli    Node 22 + agentic AI CLIs (claude/codex/gemini/opencode) + LSPs + Nerd Font
```

Each addon declares its eligibility in a short header:

```bash
# nosi-addon: agentic-cli
# description: ...
# shapes: headless desktop wsl     (or *)
# distros: ubuntu debian fedora    (or *)
# versions: *
```

Multi-reboot installs (NVIDIA CUDA + NOKM + DOCA, AMD ROCm,
MLNX_OFED) are **not** addons — they live as cijoe workflows under
`cijoe/workflows/setup_*.yaml` and run from a control box over SSH,
because cijoe's `core.wait_for_transport` step handles reboots
transparently. `nosi-addon` is for installs that finish without
asking the operator to reboot.

`apply.sh` is fail-fast: any step error aborts the chain and the
`/etc/nosi/apply-ok` sentinel never gets written. The smoketest's
whole-chain assertion checks for this sentinel; absence means the
image is refused for publish. Strict mode catches the kind of failure
that an asserted-too-narrow smoketest would miss otherwise.

## FreeBSD

`freebsd-14/15-headless` run the same `apply.sh` chain, with two
differences from the Linux variants:

* **Delivery.** FreeBSD's bake uses *nuageinit* (not Python cloud-init),
  which has no `write_files:`. So `cijoe/scripts/userdata_render.py` ships
  the whole `provision/` tree (+ `.nosi-version`) as a base64 gzip tarball
  via the `__NOSI_PROVISION_TARBALL__` marker; a single `runcmd` line
  decodes and extracts it to `/opt/nosi` before invoking apply.sh. (The
  Linux variants keep using the `write_files:` `__NOSI_PROVISION_FILES__`
  marker.)
* **Step set.** `apply.sh` runs a curated FreeBSD subset
  (`05 06 08 09 12 20 21 22 28 30 32 98 99`) whose steps carry FreeBSD
  branches using native idioms (pkg, rc.conf/`sysrc`, rc.d, base ntpd,
  growfs, pciconf/nvmecontrol) instead of apt-dnf / netplan / systemd /
  grub. The Linux-only steps (r8125 DKMS, nouveau, grub IOMMU, podman,
  snapd, userspace-PCI, rotate-password, nosi-addons) are skipped.

It is a **C/C++/Python** base: base clang/lldb + the cloud-init package
set (cmake, meson, ninja, gmake, python, helix, zellij, …) plus gdb, ruff,
uv, lazygit, oras and cijoe. **Rust and Zig are opt-in** (`pkg install rust
zig`) so llvm stays out of the baked image; yazi, pyright, taplo and
marksman are likewise omitted (heavy/Node/unavailable on FreeBSD). cijoe's
native deps (cryptography via paramiko, psutil) come from pkg as prebuilt
binaries, with cijoe itself in a `--system-site-packages` venv.

## Variants

| variant                | base                 | adds over headless |
|------------------------|----------------------|--------------------|
| `debian-13-headless`   | Debian 13 trixie     | -- |
| `ubuntu-2404-headless` | Ubuntu 24.04 noble   | -- (HW vendor stacks: cudadev/rocmdev workflows pin to this base) |
| `ubuntu-2604-headless` | Ubuntu 26.04 resolute| -- |
| `ubuntu-2604-wsl`      | Ubuntu 26.04 resolute| meld + gitk + git-gui via WSLg; .tar.gz output instead of (alongside) .img.gz |
| `fedora-44-headless`   | Fedora 44            | -- |
| `fedora-44-desktop`    | Fedora 44            | Sway + tuigreet + Firefox + audio/bluetooth/power-management |
| `freebsd-14-headless`  | FreeBSD 14.4-RELEASE | -- (C/C++/Python; apply.sh runs via nuageinit + a base64 tarball; Rust/Zig opt-in) |
| `freebsd-15-headless`  | FreeBSD 15.0-RELEASE | -- (C/C++/Python; apply.sh runs via nuageinit + a base64 tarball; Rust/Zig opt-in) |

## Use from a flashed nosi image

`apply.sh` already runs during the bake (via cloud-init's runcmd), so a
flashed image is already at parity. Re-running on an installed system
picks up upstream-latest of every binary in step 20 + Python tools in
step 22, which is how operators stay current without re-flashing:

```
sudo /opt/nosi/provision/apply.sh debian-13-headless
```

## Use on a fresh Hetzner VM (or any clean cloud VM)

Reaches the same parity as a flashed nosi image on a VM whose OS was
installed by someone else. The script clones the repo, then dispatches:

```
git clone https://github.com/safl/nosi /opt/nosi
sudo /opt/nosi/provision/apply.sh <variant>
```

Steps with kernel-side effects (r8125 DKMS, IOMMU cmdline) take effect
on next reboot. Hetzner VMs ship without RTL8125 NICs, so step 10
no-ops there.

## Use as a WSL2 distribution

The `wsl`-shape variant (today: `ubuntu-2604-wsl`) is derived from the
`ubuntu-2604-headless` base: `derive_pack` chroots into a copy of
the baked headless rootfs, runs the wsl shape step (adds meld / gitk /
git-gui), strips kernel/grub/firmware/cloud-init, and tar-gzips the
result. The `.tar.gz` is the only artifact.

Install on Windows (recommended, Win11 + WSL 2.x):

```
wsl --install --from-file path\to\nosi-ubuntu-2604-wsl.tar.gz
wsl -d nosi-wsl
```

`--from-file` reads `/etc/wsl-distribution.conf [oobe]` from the
tarball at install time and writes `defaultUid=1000` into the Windows
side registry, so the very first `wsl -d` lands as `odus` rather than
root. odus sits at the standard UID 1000 (WSL/Linux convention for
the first interactive user). See "Personalization" below if you want
your own name on the prompt instead.

GUI dev tools baked into the variant (`meld`, `gitk`, `git-gui`)
launch via WSLg's Windows-side Wayland + XWayland server -- nothing
runs inside the rootfs. `xdg-open <url>` opens links in the Windows
default browser via WSLg's interop layer.

On first interactive shell, the WSL-only profile.d snippet from
nosi's password-rotation logic prompts for `passwd` to rotate the
baked default `odus.321` to something local. Once rotated, the
prompt disappears.

### Older WSL (no `--from-file`)

`wsl --import` does not consult `wsl-distribution.conf`; the registry
`DefaultUid` stays at 0 (root) and `[user] default=odus` from
`wsl.conf` is only applied by init inside the VM after the launcher
has already picked the user, so the first session still lands as
root. Two ways out:

```
# Set the default user once via the Windows-side knob (recommended)
wsl --import nosi-wsl C:\WSL\nosi-wsl path\to\nosi-ubuntu-2604-wsl.tar.gz
wsl --manage nosi-wsl --set-default-user odus
wsl -d nosi-wsl

# Or pass -u on every launch (never updates the registry)
wsl --import nosi-wsl C:\WSL\nosi-wsl path\to\nosi-ubuntu-2604-wsl.tar.gz
wsl -d nosi-wsl -u odus
```

## Password rotation

The default `odus.321` ships **active** so a freshly flashed image is
ready for any consumer immediately: ssh password auth, ssh key auth,
sftp / scp, non-TTY automation. CI jobs that flash and run against the
image do not have to negotiate a PAM password-change challenge.

Step 29 only *marks* the system, it doesn't *force* anything:

* `/etc/nosi/default-password-active` is touched while `odus`'s hash
  matches the baked default. Step 99-motd reads it and prints a
  prominent yellow warning at every interactive login until the
  operator rotates. `passwd odus` is enough; the next `apply.sh`
  re-run detects the new hash and removes the marker (or do it by
  hand: `sudo rm /etc/nosi/default-password-active`).
* `/etc/profile.d/nosi-rotate-password.sh` *offers* (does not force)
  a `passwd` prompt on the first interactive WSL shell. Gated on TTY
  so `wsl exec`-style automation never sees it; inert outside WSL.

Operators who do want the old "force rotate on first SSH login"
behaviour can `sudo chage -d 0 odus` post-flash; nosi has stopped
imposing it by default.

## Personalization

nosi ships `odus` at UID 1000 as **the** appliance operator. There is
no nosi-supplied "first launch wizard", no `nosi-rename` helper, and
no convention for separating "the appliance" from "the human at the
keyboard". This is deliberate: the appliance identity and the human
identity can be the same thing, and trying to split them adds moving
parts without solving a real problem.

If you want your own name on the prompt anyway, two routes:

**Just use odus.** It's a 4-letter handle, doesn't reveal anything
about who you are, and every nosi piece (sudoers, wsl.conf, motd,
firstboot-inventory) assumes the account is called `odus`. Lowest
blast radius by a wide margin.

**Add a second account, leave odus alone.** Standard Linux tooling,
purely additive, doesn't touch any nosi state:

```
sudo useradd -u 1001 -m -s /bin/bash -G sudo,kvm me   # +render,video,input on desktop
sudo passwd me

# WSL only: have `wsl -d <distro>` land as `me` instead of odus
sudo sed -i 's/^default=odus$/default=me/' /etc/wsl.conf
# and, from PowerShell:
#   wsl --terminate <distro>
#   wsl --manage <distro> --set-default-user me
```

What we explicitly do not recommend: renaming odus with `usermod -l`.
The Linux rename-a-user story is full of long-tail traps that
`usermod` does not handle (`/etc/subuid` + `/etc/subgid` are keyed by
username so rootless podman silently breaks, sudoers entries can be
spread across `/etc/sudoers.d/*` and any miss locks you out of sudo,
running background processes pin the old name in kernel state, mail
spool / atjobs / cron entries are not relocated, `/run/user/1000/`
sockets get stale, etc.). It's doable but the operator owns the full
checklist; nosi will not ship a helper that pretends otherwise.
