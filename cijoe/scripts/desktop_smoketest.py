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
    DEFAULT_PASSWORD,
    SSH_HOST_PORT,
    SSH_USER,
    _ssh_password,
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
            _dump_greeter_diagnostics(serial)
            if rc == errno.ETIMEDOUT:
                _dump_greeter_diagnostics_ssh()
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


def _dump_greeter_diagnostics(serial: Path) -> None:
    """Greeter failed: surface the SELinux / greetd / relabel story from the
    WHOLE serial log (dump_serial only shows the tail). The first-boot console
    is not preserved as a CI artifact, so these grepped lines are the only
    forensic record of whether the first-boot autorelabel ran and rebooted,
    whether greetd.service or one of its dependencies failed, and whether the
    kernel logged any AVC denials. Matched against an ANSI-stripped copy."""
    raw = ""
    with contextlib.suppress(OSError):
        raw = serial.read_text(errors="replace")
    lines = _ANSI_RE.sub("", raw).splitlines()
    keys = (
        "greetd",
        "display-manager",
        "graphical.target",
        "graphical interface",
        "autorelabel",
        "relabel",
        "selinux",
        "avc:",
        "denied",
        "failed to start",
        "dependency failed",
        "start request repeated",
        "start-limit",
        "emergency",
        "failed with result",
        "condition",
    )
    hits = [ln.rstrip() for ln in lines if any(k in ln.lower() for k in keys)]
    log.error(f"---- greeter diagnostics: greetd / SELinux / relabel ({len(hits)} matches) ----")
    for ln in hits[-150:]:
        log.error(f"  {ln}")
    log.error("---- end greeter diagnostics ----")


def _greeter_up_via_ssh() -> bool:
    """Confirm the greeter directly over SSH. The serial console can be quiet
    (depending on the console set, systemd's status and the greeter markers
    never print there), yet greetd runs on the graphical VT and sshd is up by
    multi-user. So ask the box: True only when greetd.service is active AND
    graphical.target has been reached. Best-effort; any SSH error means "not
    yet" and the caller keeps polling."""
    try:
        _rc, out = _ssh_password(
            SSH_USER,
            DEFAULT_PASSWORD,
            "systemctl is-active greetd.service graphical.target 2>/dev/null",
        )
    except Exception:
        return False
    states = out.split()
    return len(states) >= 2 and all(s == "active" for s in states[:2])


def _dump_greeter_diagnostics_ssh() -> None:
    """The greeter never confirmed and the serial console was quiet: pull the
    real story over SSH (the box is up at multi-user with sshd running on a
    timeout failure). Best-effort and read-only; each command is capped so a
    chatty journal cannot flood the job log."""
    probes = (
        ("kernel cmdline", "cat /proc/cmdline"),
        ("selinux mode", "getenforce; ls -l /.autorelabel 2>&1"),
        ("failed units", "systemctl --failed --no-legend --plain 2>&1 | head -20"),
        (
            "greetd + display-manager",
            "systemctl status greetd.service display-manager.service --no-pager -l 2>&1 | head -40",
        ),
        ("graphical.target", "systemctl is-active graphical.target 2>&1"),
        ("greetd journal", "journalctl -b -u greetd.service --no-pager 2>&1 | tail -40"),
        (
            "selinux denials",
            "journalctl -b --no-pager 2>&1 | grep -iE 'avc|selinux|denied' | tail -25",
        ),
        (
            "autorelabel service",
            "systemctl status selinux-autorelabel.service --no-pager 2>&1 | head -15",
        ),
        ("greeter labels", "ls -Zd /usr/bin/greetd /etc/greetd /var/lib/greetd 2>&1"),
    )
    log.error("---- greeter SSH diagnostics ----")
    for label, cmd in probes:
        try:
            rc, out = _ssh_password(SSH_USER, DEFAULT_PASSWORD, cmd)
        except Exception as exc:
            rc, out = -1, f"(ssh error: {exc})"
        log.error(f"  == {label} (rc={rc}) ==")
        for ln in (out or "(empty)").splitlines()[:40]:
            log.error(f"     {ln}")
    log.error("---- end greeter SSH diagnostics ----")


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
            log.info(f"[PASS] {variant}: booted on {disk_if}, greeter started (serial marker)")
            return 0

        # The serial marker can be absent on a quiet console even when the
        # greeter is up on the graphical VT; confirm directly over SSH.
        if _greeter_up_via_ssh():
            log.info(f"[PASS] {variant}: booted on {disk_if}, greeter up (ssh confirm)")
            return 0

        if time.monotonic() >= end:
            log.error(
                f"[FAIL] {variant}: greeter did not start within {timeout}s "
                f"booting on {disk_if} (no greetd / graphical-target marker on serial)"
            )
            return errno.ETIMEDOUT
        time.sleep(5)
