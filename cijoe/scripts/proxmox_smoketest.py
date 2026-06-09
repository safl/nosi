"""
Boot-test the debian-13-proxmox image: PVE comes up on first boot
=================================================================

The proxmox shape is installed in a chroot bake, so the build alone cannot
prove the host actually boots and the daemons start. This decompresses the
derived ``.img.gz``, boots it in QEMU (fresh boot, no seed -- the same way a
flashed host comes up), SSHes in as the baked operator, and asserts the Proxmox
VE stack is live: pmxcfs (pve-cluster) + pvedaemon + pveproxy running, and the
web UI listening on :8006.

Reuses image_smoketest's boot / SSH-handshake helpers; only the QEMU launch
differs (more RAM for the PVE stack, a longer ready-timeout for its slower
first boot).

Retargetable: False
"""

from __future__ import annotations

import contextlib
import errno
import logging as log
import os
import shutil
from argparse import ArgumentParser
from pathlib import Path

from image_smoketest import (
    DEFAULT_PASSWORD,
    SSH_HOST_PORT,
    _dump_serial,
    _gen_ssh_keypair,
    _install_key_via_password,
    _kill_qemu,
    _make_overlay,
    _ssh,
    _wait_for_ssh_password_ready,
)

# PVE's first boot (initramfs + pmxcfs + pveproxy startup) is slower than the
# bare base image, so allow more time than image_smoketest's default.
BOOT_TIMEOUT = 360


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--variant",
        type=str,
        default="debian-13-proxmox",
        help="Derived proxmox variant to boot-test (default debian-13-proxmox).",
    )


def main(args, cijoe):
    disk_dir = Path(os.path.expanduser("~/system_imaging/disk"))
    gz = disk_dir / f"nosi-{args.variant}-x86_64.img.gz"
    if not gz.exists():
        log.error(f"proxmox image not found: {gz}")
        return errno.ENOENT

    workdir = disk_dir / f"proxmox-smoketest-{os.getpid()}"
    workdir.mkdir(parents=True, exist_ok=True)
    raw = workdir / "proxmox.raw"
    qcow2 = workdir / "proxmox.qcow2"

    # Decompress + convert to qcow2 so _make_overlay can lay a copy-on-write
    # overlay on top (the boot never mutates the published artifact).
    err, _ = cijoe.run_local(f"bash -o pipefail -c 'zcat {gz} > {raw}'")
    if err:
        log.error("failed decompressing proxmox image")
        return err
    err, _ = cijoe.run_local(f"qemu-img convert -O qcow2 {raw} {qcow2}")
    raw.unlink(missing_ok=True)
    if err:
        log.error("failed converting proxmox raw -> qcow2")
        return err

    pidfile = workdir / "qemu.pid"
    serial = workdir / "serial.log"
    rc = 1
    try:
        key, key_pub = _gen_ssh_keypair(workdir)
        overlay = _make_overlay(workdir, qcow2)
        _boot_proxmox(cijoe, overlay, pidfile, serial)

        if not _wait_for_ssh_password_ready(DEFAULT_PASSWORD, SSH_HOST_PORT, BOOT_TIMEOUT):
            log.error("proxmox VM did not become SSH-ready within the timeout")
            _dump_serial(serial)
            return errno.ETIMEDOUT

        _install_key_via_password(key_pub.read_text().strip(), DEFAULT_PASSWORD)
        rc = _assert_pve(key)
        if rc:
            _dump_serial(serial)
    finally:
        _kill_qemu(pidfile)
        if rc == 0:
            with contextlib.suppress(Exception):
                shutil.rmtree(workdir)
        else:
            log.error(f"proxmox smoketest workdir preserved for forensics: {workdir}")
    return rc


def _boot_proxmox(cijoe, overlay: Path, pidfile: Path, serial: Path) -> None:
    """Same shape as image_smoketest._boot_overlay, but 4 GiB for the PVE
    stack (pmxcfs + pvedaemon + pveproxy + postfix)."""
    cmd = (
        "qemu-system-x86_64 "
        "-machine type=q35,accel=kvm "
        "-cpu host -smp 2 -m 4G "
        "-display none -monitor none "
        f"-serial file:{serial} "
        f"-drive file={overlay},if=virtio,format=qcow2 "
        f"-netdev user,id=n1,hostfwd=tcp:127.0.0.1:{SSH_HOST_PORT}-:22 "
        "-device virtio-net-pci,netdev=n1 "
        f"-daemonize -pidfile {pidfile}"
    )
    err, _ = cijoe.run_local(cmd)
    if err:
        raise RuntimeError("qemu launch failed for proxmox boot-test")


def _assert_pve(key: Path) -> int:
    """All three core daemons active and the web UI listening on :8006."""
    ok = True

    # `is-active a b c` exits 0 only if every unit is active.
    rc, out = _ssh(key, "systemctl is-active pve-cluster pvedaemon pveproxy")
    services_ok = rc == 0
    log.info(f"[{'PASS' if services_ok else 'FAIL'}] pve daemons active: {out.strip()!r}")
    ok = ok and services_ok

    rc, out = _ssh(key, "sudo ss -Hltn 'sport = :8006' | grep -q . && echo LISTENING")
    port_ok = rc == 0 and "LISTENING" in out
    log.info(f"[{'PASS' if port_ok else 'FAIL'}] web UI on :8006: {out.strip()!r}")
    ok = ok and port_ok

    return 0 if ok else 1
