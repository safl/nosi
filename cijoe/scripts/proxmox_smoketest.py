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

# PVE's first boot (initramfs + pmxcfs + pveproxy startup) is slower than the
# bare base image, and a TCG fallback (if KVM is unavailable) is slower still,
# so allow generous time.
BOOT_TIMEOUT = 600


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

    # Decompress + convert to qcow2 so make_overlay can lay a copy-on-write
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
        key, key_pub = gen_ssh_keypair(workdir)
        overlay = make_overlay(workdir, qcow2)
        _boot_proxmox(cijoe, overlay, pidfile, serial)

        if not wait_for_ssh_password_ready(DEFAULT_PASSWORD, SSH_HOST_PORT, BOOT_TIMEOUT):
            log.error("proxmox VM did not become SSH-ready within the timeout")
            dump_serial(serial)
            return errno.ETIMEDOUT

        install_key_via_password(key_pub.read_text().strip(), DEFAULT_PASSWORD)
        rc = _assert_pve(key)
        if rc:
            dump_serial(serial)
    finally:
        kill_qemu(pidfile)
        if rc == 0:
            with contextlib.suppress(Exception):
                shutil.rmtree(workdir)
        else:
            log.error(f"proxmox smoketest workdir preserved for forensics: {workdir}")
    return rc


def _boot_proxmox(cijoe, overlay: Path, pidfile: Path, serial: Path) -> None:
    """Same shape as image_smoketest._boot_overlay, but 4 GiB for the PVE
    stack (pmxcfs + pvedaemon + pveproxy + postfix). This runs late in the job
    (after the long derive step), by which point the runner's /dev/kvm perms
    set once at job start can have reverted, so re-grant access; accel=kvm:tcg
    falls back to software emulation if KVM is genuinely unavailable rather than
    hard-failing. `-cpu max` (not `host`) so a TCG fallback still works."""
    cijoe.run_local("sudo chmod 0666 /dev/kvm 2>/dev/null || true")
    cmd = (
        "qemu-system-x86_64 "
        "-machine type=q35,accel=kvm:tcg "
        "-cpu max -smp 2 -m 4G "
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


def _assert_pve(key: Path, timeout: int = 360) -> int:
    """Daemons active, web UI serving TLS with a real node cert, operator
    can log in.

    The first real-hardware flash surfaced that "daemons active + port
    listening" is not "working": `pvecm updatecerts` refuses a hostname that
    resolves to 127.0.1.1, so the node had no pve-ssl.pem and the UI could
    not complete TLS -- while every is-active check stayed green. Assert the
    outcomes instead: the cert exists, https://:8006 answers 200 (TLS
    actually handshakes), and odus@pam holds the Administrator ACL (root
    ships locked; without the grant the UI is up but no one can log in).

    Polls rather than checking once: sshd comes up before the PVE stack
    (and the nosi-proxmox-online oneshot) finishes settling, so an instant
    check races the startup. Passes as soon as everything is up.

    The timeout is generous (360s) because _boot_proxmox uses accel=kvm:tcg:
    by the time this boot-test runs (late in the job) the runner's /dev/kvm
    access can have reverted, dropping QEMU to TCG software emulation where
    the full PVE stack settles several times slower. The box is healthy in
    that case, just slow, so a tight bound would flake; 360s clears the
    TCG-emulated path while a KVM boot still passes in well under a minute."""
    end = time.monotonic() + timeout
    last = "(no check yet)"
    while True:
        # `is-active a b c` exits 0 only if every unit is active.
        rc_s, out_s = ssh_run(key, "systemctl is-active pve-cluster pvedaemon pveproxy")
        services_ok = rc_s == 0
        rc_u, out_u = ssh_run(
            key,
            "sudo test -s /etc/pve/local/pve-ssl.pem && "
            "curl -ks -o /dev/null -w %{http_code} https://127.0.0.1:8006/",
        )
        ui_ok = rc_u == 0 and out_u.strip().endswith("200")
        rc_a, out_a = ssh_run(key, "sudo pveum acl list 2>/dev/null | grep -c odus@pam || true")
        admin_ok = rc_a == 0 and out_a.strip() not in ("", "0")
        if services_ok and ui_ok and admin_ok:
            log.info(
                f"[PASS] PVE up: daemons={out_s.strip()!r}, UI https 200 "
                "with node cert, odus@pam is Administrator"
            )
            return 0
        last = (
            f"daemons={out_s.strip()!r} (rc={rc_s}); "
            f"ui={'200+cert' if ui_ok else out_u.strip() or 'down'}; "
            f"admin={'granted' if admin_ok else 'missing'}"
        )
        if time.monotonic() >= end:
            break
        time.sleep(10)
    log.info(f"[FAIL] PVE not up within {timeout}s: {last}")
    return 1
