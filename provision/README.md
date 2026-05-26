# nosi provision

System tweaks and toolchain installs that turn a fresh Debian / Ubuntu /
Fedora cloud-init bake (or a fresh Hetzner VM, or a WSL2 import) into a
nosi-parity machine.

Each script under `steps/` is standalone, idempotent, and cross-distro
where the work is genuinely the same (DKMS, modprobe.d, systemd units,
profile.d snippets); per-distro otherwise. `apply.sh <flavor>` runs the
whole chain in order. `lib/common.sh` provides distro detection
(`NOSI_DISTRO`, `NOSI_PKGMGR`), package-manager wrappers, logging, and
an idempotency helper that skips writing files whose content has not
changed.

```
provision/
├── apply.sh              # entry point: apply.sh <flavor>
├── lib/common.sh         # distro detect, logging, helpers
└── steps/
    ├── 05-nosi-release.sh          # FIRST: /etc/nosi-release with build identity
    ├── 10-r8125-dkms.sh
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
    ├── 40..43                      # aidev-only: nerd font, npm globals, pi, wsl.conf
    └── 99-motd.sh                  # LAST: login banner = "all earlier steps ran"
```

`apply.sh` continues past a failing step, accumulates the list, and exits
non-zero at the end with the names of the failures. That way a single
broken step (transient pip / curl flake, missing pkg in a new distro
release) no longer silently skips every step after it, and the bake log
shows exactly which steps need attention.

## Flavors

| flavor          | distro    | adds over sysdev       |
|-----------------|-----------|------------------------|
| `debian-sysdev` | Debian 13 | --                     |
| `ubuntu-sysdev` | Ubuntu LTS| --                     |
| `fedora-sysdev` | Fedora    | --                     |
| `ubuntu-aidev`  | Ubuntu LTS| Node, agentic CLIs, JetBrainsMono Nerd Font, WSL config |

## Use from a flashed nosi image

`apply.sh` already runs during the bake (via cloud-init's runcmd), so a
flashed image is already at parity. Re-running on an installed system
picks up upstream-latest of every binary in step 20 + Python tools in
step 22, which is how operators stay current without re-flashing:

```
sudo /opt/nosi/provision/apply.sh debian-sysdev
```

## Use on a fresh Hetzner VM (or any clean cloud VM)

Reaches the same parity as a flashed nosi image on a VM whose OS was
installed by someone else. The script clones the repo, then dispatches:

```
git clone https://github.com/safl/nosi /opt/nosi
sudo /opt/nosi/provision/apply.sh <flavor>
```

Steps with kernel-side effects (r8125 DKMS, IOMMU cmdline) take effect
on next reboot. Hetzner VMs ship without RTL8125 NICs, so step 10
no-ops there.

## Use as a WSL2 distribution

The aidev bake produces both a flashable `.img.gz` and a WSL2 rootfs
tarball (`wsl_rootfs_publish` strips kernel/grub/firmware/cloud-init).

Install on Windows (recommended, Win11 + WSL 2.x):

```
wsl --install --from-file path\to\nosi-aidev.tar.gz
wsl -d nosi-aidev
```

`--from-file` reads `/etc/wsl-distribution.conf [oobe]` from the
tarball at install time and writes `defaultUid=1000` into the Windows
side registry, so the very first `wsl -d` lands as `odus` rather than
root. odus sits at the standard UID 1000 (WSL/Linux convention for
the first interactive user). See "Personalization" below if you want
your own name on the prompt instead.

On first interactive shell, the WSL-only profile.d snippet from step
29 prompts for `passwd` to rotate the baked default `odus.321` to
something local. Once rotated, the prompt disappears.

### Older WSL (no `--from-file`)

`wsl --import` does not consult `wsl-distribution.conf`; the registry
`DefaultUid` stays at 0 (root) and `[user] default=odus` from
`wsl.conf` is only applied by init inside the VM after the launcher
has already picked the user, so the first session still lands as
root. Two ways out:

```
# Set the default user once via the Windows-side knob (recommended)
wsl --import nosi-aidev C:\WSL\nosi-aidev path\to\nosi-aidev.tar.gz
wsl --manage nosi-aidev --set-default-user odus
wsl -d nosi-aidev

# Or pass -u on every launch (never updates the registry)
wsl --import nosi-aidev C:\WSL\nosi-aidev path\to\nosi-aidev.tar.gz
wsl -d nosi-aidev -u odus
```

## Password rotation

Step 29 marks the baked `odus.321` as expired:

* `chage -d 0 odus` makes `login(1)` and `sshd-via-PAM` force a change
  before granting a shell. Works for any SSH client that connects with
  a TTY (`ssh -t odus@host`); non-TTY connections fail closed until
  the password is rotated.
* `/etc/profile.d/nosi-rotate-password.sh` covers WSL2, where the
  session bypasses login + PAM. Inert outside WSL.

Skip is detected by comparing `/etc/shadow`'s hash to the baked one,
so re-running `apply.sh` on a system whose operator has already
rotated does not touch the password.

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
sudo useradd -u 1001 -m -s /bin/bash -G sudo,kvm me   # +render,video on aidev
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
