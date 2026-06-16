"""
Boot-test a desktop derive: it boots on NVMe and the greeter comes up
====================================================================

The desktop shape is built by derive_pack (a chroot re-provision of the baked
headless qcow2, no re-bake), so the build alone never boots it. That is exactly
how a host-only initramfs shipped: the derive re-runs provisioning, step 15's
``dracut --force`` rebuilds the initramfs in the chroot, and on Fedora that was
host-only, so the flashed desktop kernel-panicked on hardware unlike the build
VM while the headless base (booted by image_smoketest) stayed green.

This closes that blind spot. It decompresses the derived ``.img.gz`` and boots
it in QEMU as a fresh flashed box (no seed) on an NVMe controller, then judges
the result from the serial console:

  1. The image boots on NVMe. The bake and image_smoketest both use virtio, so
     a host-only initramfs carries virtio and would boot there even when broken.
     NVMe is a common real root controller and is absent from a virtio-profiled
     host-only initramfs, so a regression cannot mount root and the kernel
     panics. This is the regression test for the panic, and a panic on the
     serial fails the check immediately.
  2. The greeter actually starts: greetd reaches its systemd unit and the box
     gets to the graphical login.

Judged from the serial log rather than over SSH on purpose. A desktop boots
into a graphical session where SSH is secondary, and under that boot load sshd
can be slow to answer (an early run here timed out on the SSH banner while the
image had in fact booted and started greetd). The serial console shows the boot
outcome directly, with no dependency on the network stack settling.

Reuses image_smoketest's QEMU helpers; the disk wiring (NVMe) and the
serial-based assertion are the only differences.

Retargetable: False
"""

from __future__ import annotations

import contextlib
import errno
import logging as log
import os
import re
import shutil
import time
from argparse import ArgumentParser
from pathlib import Path

from image_smoketest import (
    SSH_HOST_PORT,
    dump_serial,
    kill_qemu,
    make_overlay,
)

# A desktop first boot reaches the greeter a bit slower than the headless base,
# a TCG fallback (no KVM) is slower still, and the Fedora desktop does a
# one-time SELinux relabel + reboot on first boot (see 50-desktop-stack), so
# allow generous time for two boots.
BOOT_TIMEOUT = 600

# Serial markers, matched against an ANSI-stripped, lower-cased copy of the
# console: systemd colorizes unit names (`Started \x1b[...mgreetd.service`), so
# a plain substring of the un-stripped text never matches across the escape
# codes. Either greetd's unit starting or the graphical target being reached
# proves the box booted into its login. The panic markers are the regression we
# are hunting: a host-only initramfs that cannot mount root on this controller
# prints one of these instead.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
GREETER_MARKERS = (
    "started greetd.service",
    "reached target graphical",
)
PANIC_MARKERS = (
    "kernel panic",
    "unable to mount root",
)
# sshd must come up. The Fedora desktop's chroot-mislabeled SELinux made it
# "Failed to start sshd.service" on first boot (fixed by the first-boot relabel
# in 50-desktop-stack); fail the boot-test if that regression reappears, so a
# green run is real proof sshd starts, not just that the greeter did. Covers
# Fedora's sshd.service and Debian's ssh.service unit names.
SSHD_FAIL_MARKERS = (
    "failed to start sshd.service",
    "failed to start ssh.service",
    "failed to start openssh",
)


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--variant",
        type=str,
        default=None,
        help=(
            "Desktop variant to boot-test (e.g. fedora-44-desktop). Default: "
            "derive it from the config's base [nosi].variant by swapping the "
            "shape to desktop, so one task line serves every desktop-producing leg."
        ),
    )
    parser.add_argument(
        "--disk-if",
        type=str,
        default="nvme",
        choices=("nvme", "ahci", "virtio"),
        help=(
            "Disk controller to boot on. Defaults to nvme so a host-only "
            "initramfs regression fails to mount root; ahci/virtio are escape "
            "hatches if a runner's SeaBIOS cannot boot the chosen controller."
        ),
    )


def _desktop_variant(cijoe) -> str:
    """Derive the desktop variant from the base config's [nosi].variant by
    swapping the trailing shape, e.g. ``fedora-44-headless`` -> ``fedora-44-desktop``.
    Returns "" when there is nothing to derive from."""
    base = cijoe.getconf("nosi", {}).get("variant", "")
    if not base:
        return ""
    return base.rsplit("-", 1)[0] + "-desktop"


def main(args, cijoe):
    variant = args.variant or _desktop_variant(cijoe)
    if not variant:
        log.error("could not resolve a desktop variant from --variant or config")
        return errno.EINVAL

    disk_dir = Path(os.path.expanduser("~/system_imaging/disk"))
    gz = disk_dir / f"nosi-{variant}-x86_64.img.gz"
    if not gz.exists():
        log.error(f"desktop image not found: {gz}")
        return errno.ENOENT

    workdir = disk_dir / f"desktop-smoketest-{os.getpid()}"
    workdir.mkdir(parents=True, exist_ok=True)
    raw = workdir / "desktop.raw"
    qcow2 = workdir / "desktop.qcow2"

    # Decompress + convert to qcow2 so make_overlay can lay a copy-on-write
    # overlay on top (the boot never mutates the published artifact).
    err, _ = cijoe.run_local(f"bash -o pipefail -c 'zcat {gz} > {raw}'")
    if err:
        log.error("failed decompressing desktop image")
        return err
    err, _ = cijoe.run_local(f"qemu-img convert -O qcow2 {raw} {qcow2}")
    raw.unlink(missing_ok=True)
    if err:
        log.error("failed converting desktop raw to qcow2")
        return err

    pidfile = workdir / "qemu.pid"
    serial = workdir / "serial.log"
    rc = 1
    try:
        overlay = make_overlay(workdir, qcow2)
        _boot_desktop(cijoe, overlay, pidfile, serial, args.disk_if)
        rc = _await_greeter(serial, variant, args.disk_if, BOOT_TIMEOUT)
        if rc:
            dump_serial(serial)
    finally:
        kill_qemu(pidfile)
        if rc == 0:
            with contextlib.suppress(Exception):
                shutil.rmtree(workdir)
        else:
            log.error(f"desktop smoketest workdir preserved for forensics: {workdir}")
    return rc


def _boot_desktop(cijoe, overlay: Path, pidfile: Path, serial: Path, disk_if: str) -> None:
    """Same shape as image_smoketest._boot_overlay, but the root disk is wired
    to an NVMe (or ahci) controller instead of virtio so the boot exercises a
    generic initramfs. This runs late in the job (after the long derive step),
    by which point the runner's /dev/kvm perms set once at job start can have
    reverted, so re-grant access; accel=kvm:tcg falls back to software emulation
    if KVM is genuinely unavailable rather than hard-failing. `-cpu max` (not
    `host`) so a TCG fallback still works. The user-mode netdev is kept so the
    boot is realistic, but nothing here connects to it; the verdict is read off
    the serial console."""
    cijoe.run_local("sudo chmod 0666 /dev/kvm 2>/dev/null || true")
    if disk_if == "virtio":
        disk = f"-drive file={overlay},if=virtio,format=qcow2 "
    elif disk_if == "ahci":
        disk = (
            f"-drive file={overlay},if=none,id=d0,format=qcow2 "
            "-device ahci,id=ahci -device ide-hd,bus=ahci.0,drive=d0 "
        )
    else:  # nvme (default)
        disk = (
            f"-drive file={overlay},if=none,id=d0,format=qcow2 -device nvme,serial=nosi,drive=d0 "
        )
    cmd = (
        "qemu-system-x86_64 "
        "-machine type=q35,accel=kvm:tcg "
        "-cpu max -smp 2 -m 2G "
        "-display none -monitor none "
        f"-serial file:{serial} "
        f"{disk}"
        f"-netdev user,id=n1,hostfwd=tcp:127.0.0.1:{SSH_HOST_PORT}-:22 "
        "-device virtio-net-pci,netdev=n1 "
        f"-daemonize -pidfile {pidfile}"
    )
    err, _ = cijoe.run_local(cmd)
    if err:
        raise RuntimeError("qemu launch failed for desktop boot-test")


def _await_greeter(serial: Path, variant: str, disk_if: str, timeout: int) -> int:
    """Poll the serial log until the greeter is up (PASS), or fail on a kernel
    panic (the initramfs could not mount root on this controller), an sshd
    start failure (the SELinux-relabel regression), or the timeout. Reads the
    whole file each pass; serial logs for a boot are small and this runs at a
    5s cadence."""
    end = time.monotonic() + timeout
    while True:
        raw = ""
        with contextlib.suppress(OSError):
            raw = serial.read_text(errors="replace")
        text = _ANSI_RE.sub("", raw).lower()

        panic = next((m for m in PANIC_MARKERS if m in text), None)
        if panic:
            log.error(
                f"[FAIL] {variant}: kernel panic on {disk_if} boot ({panic!r}); "
                "a host-only initramfs cannot mount root on this controller"
            )
            return errno.EIO

        sshd_fail = next((m for m in SSHD_FAIL_MARKERS if m in text), None)
        if sshd_fail:
            log.error(
                f"[FAIL] {variant}: sshd failed to start on {disk_if} boot "
                f"({sshd_fail!r}); the SELinux relabel did not fix the ssh labels"
            )
            return errno.EIO

        if any(m in text for m in GREETER_MARKERS):
            log.info(f"[PASS] {variant}: booted on {disk_if} and the greeter started")
            return 0

        if time.monotonic() >= end:
            log.error(
                f"[FAIL] {variant}: greeter did not start within {timeout}s "
                f"booting on {disk_if} (no greetd / graphical-target marker on serial)"
            )
            return errno.ETIMEDOUT
        time.sleep(5)
