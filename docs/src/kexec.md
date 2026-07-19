# Custom kernel under netboot (kexec)

Under bty/pixie netboot, the kernel and initrd that boot on the target
come from the appliance's netboot bundle URL, not the target's local
`/boot`. Installing a kernel package on the running target (`apt install
linux-image-...`, `dnf install kernel`, or a locally-built `.deb`) writes
files into `/boot` on the overlay, but the next power-cycle fetches the
appliance's kernel again and those files sit unused.

`kexec` bridges that gap. The netboot-served kernel comes up, the target
lands in userspace, and the operator manually switches to a
locally-installed kernel with `kexec -l` followed by `systemctl kexec`.
The running system loads the new kernel into memory, tears down the old
one, and boots into the new one without going through firmware or the
appliance again.

Every netboot-shipping nosi variant (`debian-13-headless`,
`ubuntu-2404-headless`, `ubuntu-2604-headless`, `fedora-44-headless`)
bakes `kexec-tools` in, so `kexec` is available out of the box.

## Prerequisites

The kernel and initrd have to live on storage that survives the pivot
into userspace. Under nbdboot that means a persistent overlay: on pixie
the machine's binding needs an `overlay_profile` set (see pixie's
"Overlay profile" field on the machine detail page). Without it the
target boots on an ephemeral tmpfs upper and any locally-installed
kernel evaporates on the next reset.

Flash mode is the other supported path for kernel-heavy dev machines.
There the appliance flashes the whole nosi image to local disk, and
subsequent boots are ordinary (grub, local `/boot`, `apt install
linux-image-*` reboots as normal). If you flip between kernels every
day, flash mode is the simpler shape; if you want the target to keep
its "cattle" appearance most of the time and only occasionally test a
kernel, netboot + kexec is what this page is about.

## Install a kernel on the target

The mechanics are ordinary distro package management, run on the
target while it's netbooted. Debian/Ubuntu:

```
sudo apt update
sudo apt install linux-image-generic-hwe-26.04  # or another kernel package
```

Fedora:

```
sudo dnf install kernel
```

For a custom kernel from source, build on the target (the persistent
overlay's headers match the running kernel; `linux-headers-generic` /
`kernel-devel` are already installed) and package it:

```
git clone --depth=1 --branch v6.11 \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
cd linux
cp /boot/config-$(uname -r) .config
make olddefconfig
make -j$(nproc) bindeb-pkg LOCALVERSION=-custom     # Debian/Ubuntu
sudo dpkg -i ../linux-image-*.deb ../linux-headers-*.deb
```

or on Fedora:

```
make -j$(nproc) rpm-pkg
sudo dnf install ~/rpmbuild/RPMS/x86_64/kernel-*.rpm
```

All artifacts land in the persistent overlay's `/boot`. Verify:

```
ls /boot/vmlinuz-* /boot/initrd.img-*
```

## kexec into the installed kernel

Point `kexec -l` at the installed kernel and initrd, reuse the current
cmdline (so the netboot's `bty.nbd=` / `pixie.persist=1` args stay
in play), then trigger the switch with `systemctl kexec`:

```
K=6.11.0-generic                              # or whatever version you installed
sudo kexec -l /boot/vmlinuz-${K} \
    --initrd=/boot/initrd.img-${K} \
    --reuse-cmdline
sudo systemctl kexec
```

The current kernel prints a kexec message, tears down userspace, and
the new kernel comes up. `uname -r` after the reconnect confirms which
kernel is running.

For a bespoke cmdline (adding `kgdbwait`, a `nomodeset`, or dropping an
arg the netboot bundle set):

```
sudo kexec -l /boot/vmlinuz-${K} \
    --initrd=/boot/initrd.img-${K} \
    --command-line="$(cat /proc/cmdline) kgdbwait"
sudo systemctl kexec
```

## Recovery from a bad kernel

If the locally-installed kernel panics, hangs, or wedges the network,
the fix is to power-cycle the target from the appliance / BMC. The
netboot flow reruns from firmware and lands on the appliance's kernel
again, which is unchanged. The bad kernel package is still installed
in the overlay, so nothing kexec's into it automatically; you're back
at a working shell.

To remove the bad kernel:

```
sudo apt purge linux-image-<version>
# or on Fedora: sudo dnf remove kernel-<version>
```

If you want a "boot into the operator's kernel every time" flow, wrap
the two `kexec` commands in a systemd unit ordered early in userspace
and gate it on a marker file the operator drops when they explicitly
want the kexec loop. That's operator-owned; no service ships in the
image, on purpose, so a broken kernel install never turns into a
reset-loop.

## When to reach for flash mode instead

Flash mode is the right shape when the target is primarily a kernel-dev
box and every boot should just run whatever's in local `/boot`. The
appliance flashes a nosi image to local disk once; from then on the
machine boots ordinarily. `apt install linux-image-*` + reboot is
enough. You give up the "instant reset back to a known state" and the
shared-bytes-across-fleet properties of netboot, in exchange for a
standard workstation boot flow.

Netboot + kexec is worth it when the machine spends most of its life
as fleet cattle (CI, appliance workload, shared dev target) and only
occasionally needs to run a bespoke kernel for a session.
