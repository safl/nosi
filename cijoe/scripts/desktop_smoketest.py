"""
Boot-test a desktop derive: it boots on NVMe and the greeter comes up
====================================================================

The desktop shape is built by derive_pack (a chroot re-provision of the baked
headless qcow2, no re-bake), so the build alone never boots it. That is exactly
how a host-only initramfs shipped: the derive re-runs provisioning, step 15's
``dracut --force`` rebuilds the initramfs in the chroot, and on Fedora that was
host-only, so the flashed desktop kernel-panicked on hardware unlike the build
VM while the headless base (booted by image_smoketest) stayed green.

This closes that blind spot. It decompresses the derived ``.img.gz``, boots it
in QEMU as a fresh flashed box (no seed), and asserts two things that only a
real boot can prove:

  1. The image boots on an NVMe controller. The bake and image_smoketest both
     use virtio, so a host-only initramfs carries virtio and would boot there
     even when broken. NVMe is the common real root controller and is absent
     from a virtio-profiled host-only initramfs, so booting here fails to mount
     root unless the initramfs is generic. This is the regression test for the
     kernel panic.
  2. greetd is enabled and actually running at the graphical target, with its
     PAM stack in place (the login path that was broken on Fedora).

Reuses image_smoketest's boot / SSH-handshake helpers; only the QEMU disk wiring
(NVMe instead of virtio) and the assertions differ.

Retargetable: False
"""

from __future__ import annotations

import contextlib
import errno
import logging as log
import os
import shutil
import time
from argparse import ArgumentParser
from pathlib import Path

from image_smoketest import (
    DEFAULT_PASSWORD,
    SSH_HOST_PORT,
    dump_serial,
    gen_ssh_keypair,
    install_key_via_password,
    kill_qemu,
    make_overlay,
    ssh_run,
    wait_for_ssh_password_ready,
)

# A desktop first boot reaches the greeter a bit slower than the headless base,
# and a TCG fallback (no KVM) is slower still, so allow generous time.
BOOT_TIMEOUT = 600


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
        key, key_pub = gen_ssh_keypair(workdir)
        overlay = make_overlay(workdir, qcow2)
        _boot_desktop(cijoe, overlay, pidfile, serial, args.disk_if)

        if not wait_for_ssh_password_ready(DEFAULT_PASSWORD, SSH_HOST_PORT, BOOT_TIMEOUT):
            log.error(
                f"desktop VM did not become SSH-ready within {BOOT_TIMEOUT}s "
                f"booting on {args.disk_if} (a host-only initramfs cannot mount "
                "root on this controller and panics)"
            )
            dump_serial(serial)
            return errno.ETIMEDOUT

        install_key_via_password(key_pub.read_text().strip(), DEFAULT_PASSWORD)
        rc = _assert_desktop(key)
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
    `host`) so a TCG fallback still works."""
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


def _assert_desktop(key: Path, timeout: int = 120) -> int:
    """The greeter is the desktop login path, and reaching SSH already proved
    the generic initramfs mounted root on the test controller.

    Asserts the graphical login is live, not merely configured: greetd.service
    enabled AND active, its PAM stack present (the file whose absence denied
    every Fedora greeter login), and graphical.target the default. Polls for
    is-active because sshd answers before greetd has finished settling at the
    graphical target, so an instant check races startup; passes as soon as it
    is up."""
    end = time.monotonic() + timeout
    last = "(no check yet)"
    while True:
        rc_e, out_e = ssh_run(key, "systemctl is-enabled greetd.service")
        enabled_ok = rc_e == 0 and out_e.strip() == "enabled"
        rc_a, out_a = ssh_run(key, "systemctl is-active greetd.service")
        active_ok = rc_a == 0 and out_a.strip() == "active"
        rc_p, _ = ssh_run(key, "test -f /etc/pam.d/greetd")
        pam_ok = rc_p == 0
        rc_t, out_t = ssh_run(key, "systemctl get-default")
        target_ok = rc_t == 0 and out_t.strip() == "graphical.target"
        if enabled_ok and active_ok and pam_ok and target_ok:
            log.info(
                "[PASS] desktop up: greetd enabled+active, /etc/pam.d/greetd "
                "present, default target graphical"
            )
            return 0
        last = (
            f"greetd is-enabled={out_e.strip()!r} is-active={out_a.strip()!r}; "
            f"pam={'present' if pam_ok else 'MISSING'}; "
            f"default-target={out_t.strip()!r}"
        )
        if time.monotonic() >= end:
            break
        time.sleep(10)
    log.info(f"[FAIL] desktop not up within {timeout}s: {last}")
    return 1
