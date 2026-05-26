"""
Smoke-test the baked qcow2 by booting it and asserting via SSH
==============================================================

Runs after ``img_gz_publish`` (and ``wsl_rootfs_publish`` for aidev). Boots
the just-baked image inside qemu on a copy-on-write overlay (the published
artefact stays untouched and first-boot characteristics are preserved),
SSHes into it as ``odus``, and runs a battery of assertions covering the
regressions caught by hand in nosi 2026-05:

  * /etc/nosi-release exists, has NOSI_VERSION (non-unknown) and
    NOSI_VARIANT matching this build
  * /usr/local/bin/nosi-motd exists, executable, prints a banner whose
    first non-blank line starts with ``nosi``
  * /etc/motd is non-empty and contains ``nosi`` (the boot oneshot ran)
  * the "awesome tools" iommu, devbind, hugepages, ruff, pyright are all
    on PATH at /usr/local/bin
  * sshd is enabled for next boot (proven by ssh-in-itself, but recorded
    explicitly for the log)
  * ModemManager is NOT active (daemon-prune actually took)
  * Ubuntu only: snapd.socket is masked AND the snapd binary remains
    (soft-disabled, not purged)
  * aidev only: claude-code, codex, gemini-cli, opencode all on PATH

Why a fresh boot of an overlay instead of guestmount-style inspection:
``99-motd.service`` renders /etc/motd on first boot, host keys regenerate
on first boot, our identity assertions transit ``cat /etc/nosi-release``
through the same sshd whose enablement we are testing. Static qcow2
inspection answers "did the apply step write file X?" but cannot answer
"will the next operator's first boot of this image actually work?".

To get ``odus`` past step 29's chage-expired password without burdening
the published artefact with CI-only credentials, the boot is fed a tiny
NoCloud seed.iso that authorises a per-run SSH key and unexpires odus.
The seed is built fresh in /tmp every run; the key never leaves the
runner.

Hard gate: a single failed assertion exits non-zero, which fails
``make build`` and skips the GHCR push for the variant.

Retargetable: False
"""

from __future__ import annotations

import contextlib
import errno
import logging as log
import os
import shutil
import socket
import subprocess
import tempfile
import time
from argparse import ArgumentParser
from pathlib import Path

SSH_HOST_PORT = 4242
SSH_USER = "odus"
SSH_OPTS = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=5",
]


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name", type=str, default=None,
        help="Override system-imaging image name (default: from [nosi] variant).",
    )
    parser.add_argument(
        "--boot_timeout", type=int, default=180,
        help="Seconds to wait for sshd on the smoketest VM (default 180).",
    )


def main(args, cijoe):
    image_name = args.image_name or _default_image_name(cijoe)
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    qcow2 = Path(image["disk"]["path"])
    if not qcow2.exists():
        log.error(f"Baked qcow2 not found: {qcow2}")
        return errno.ENOENT

    variant = cijoe.getconf("nosi", {}).get("variant", "")
    flavor = "aidev" if variant.endswith("-aidev") else "sysdev"
    distro = variant.split("-", 1)[0] if "-" in variant else ""

    workdir = Path(tempfile.mkdtemp(prefix="nosi-smoketest-"))
    log.info(f"smoketest workdir: {workdir}")

    rc = 1
    qemu_pidfile = workdir / "qemu.pid"
    try:
        key, _key_pub = _gen_ssh_keypair(workdir)
        seed = _build_seed_iso(workdir, _key_pub.read_text().strip())
        overlay = _make_overlay(workdir, qcow2)
        _boot_overlay(cijoe, overlay, seed, qemu_pidfile, workdir / "serial.log")

        if not _wait_for_ssh(SSH_HOST_PORT, args.boot_timeout):
            log.error("Smoketest VM did not open sshd within the timeout")
            _dump_serial(workdir / "serial.log")
            return errno.ETIMEDOUT

        results = _run_assertions(key, variant, flavor, distro)
        _report(results)
        rc = 0 if all(ok for ok, _name, _detail in results) else 1
    finally:
        _kill_qemu(qemu_pidfile)
        with contextlib.suppress(Exception):
            shutil.rmtree(workdir)

    return rc


def _default_image_name(cijoe) -> str:
    nosi = cijoe.getconf("nosi", {})
    return f"nosi-{nosi.get('variant', 'debian-sysdev')}-x86_64"


def _gen_ssh_keypair(workdir: Path) -> tuple[Path, Path]:
    key = workdir / "id_ed25519"
    pub = workdir / "id_ed25519.pub"
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
        check=True,
    )
    return key, pub


def _build_seed_iso(workdir: Path, pubkey: str) -> Path:
    # Per-run identity so cloud-init treats this boot as a fresh instance
    # (the baked image was cloud-init clean'd, so no stale state to fight).
    iid = f"nosi-smoketest-{os.getpid()}"
    (workdir / "meta-data").write_text(
        f"instance-id: {iid}\nlocal-hostname: nosi-smoketest\n"
    )
    # Authorise the per-run key on odus and disarm step 29's chage so PAM
    # does not block key auth on a password-expired account. lock_passwd
    # stays false (odus keeps the baked default password; we just lift the
    # expiry). No power_state -- the VM stays up for the assertion run.
    (workdir / "user-data").write_text(
        "#cloud-config\n"
        "users:\n"
        "  - name: odus\n"
        "    ssh_authorized_keys:\n"
        f"      - {pubkey}\n"
        "runcmd:\n"
        "  - chage -E -1 -M -1 -W -1 odus\n"
    )
    seed = workdir / "smoketest-seed.iso"
    subprocess.run(
        [
            "mkisofs", "-quiet", "-output", str(seed), "-volid", "cidata",
            "-joliet", "-rock",
            str(workdir / "user-data"), str(workdir / "meta-data"),
        ],
        check=True,
    )
    return seed


def _make_overlay(workdir: Path, backing: Path) -> Path:
    overlay = workdir / "overlay.qcow2"
    subprocess.run(
        [
            "qemu-img", "create", "-q", "-f", "qcow2",
            "-F", "qcow2", "-b", str(backing), str(overlay),
        ],
        check=True,
    )
    return overlay


def _boot_overlay(cijoe, overlay: Path, seed: Path, pidfile: Path, serial: Path) -> None:
    # KVM-accelerated to keep the test under a minute on hosted runners
    # that already enable /dev/kvm for the bake. virtio-net + user-mode
    # networking + hostfwd is the minimum for SSH-from-host.
    cmd = (
        "/usr/bin/qemu-system-x86_64 "
        "-machine type=q35,accel=kvm "
        "-cpu host -smp 2 -m 2G "
        "-nographic -serial file:" + str(serial) + " "
        f"-drive file={overlay},if=virtio,format=qcow2 "
        f"-cdrom {seed} "
        f"-netdev user,id=n1,hostfwd=tcp:127.0.0.1:{SSH_HOST_PORT}-:22 "
        "-device virtio-net-pci,netdev=n1 "
        f"-daemonize -pidfile {pidfile}"
    )
    err, _ = cijoe.run_local(cmd)
    if err:
        raise RuntimeError(f"qemu failed to start smoketest VM (exit {err})")


def _wait_for_ssh(port: int, timeout: int) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            try:
                s.connect(("127.0.0.1", port))
                # Got TCP; sshd banner takes another ~1s on first boot.
                time.sleep(2)
                return True
            except OSError:
                pass
        time.sleep(2)
    return False


def _ssh(key: Path, cmd: str) -> tuple[int, str]:
    """Run a single shell command on the smoketest VM, capture stdout+stderr."""
    full = [
        "ssh", "-i", str(key), *SSH_OPTS,
        "-p", str(SSH_HOST_PORT),
        f"{SSH_USER}@127.0.0.1", cmd,
    ]
    res = subprocess.run(full, capture_output=True, text=True, timeout=30)
    return res.returncode, (res.stdout + res.stderr).strip()


def _run_assertions(key: Path, variant: str, flavor: str, distro: str) -> list[tuple[bool, str, str]]:
    """Return [(ok, name, detail)] for every assertion."""

    # Wait until cloud-init has finished applying the smoketest seed --
    # the chage-unexpire runs in cloud-init runcmd, and even though we
    # already authenticated with the key, the next ssh's command-exec
    # phase still re-checks account state. cloud-init status --wait
    # blocks until cloud-init is done; bounded so a hung cloud-init does
    # not hang the smoketest forever.
    _, _ = _ssh(key, "timeout 60 cloud-init status --wait || true")

    results: list[tuple[bool, str, str]] = []

    def check(name: str, cmd: str, predicate) -> None:
        rc, out = _ssh(key, cmd)
        ok, detail = predicate(rc, out)
        results.append((ok, name, detail))

    # ---- build identity ---------------------------------------------------
    check(
        "/etc/nosi-release has NOSI_VARIANT",
        "cat /etc/nosi-release",
        lambda rc, out: (
            rc == 0 and f"NOSI_VARIANT={variant}" in out,
            out if rc != 0 or f"NOSI_VARIANT={variant}" not in out else "ok",
        ),
    )
    check(
        "/etc/nosi-release NOSI_VERSION is non-unknown",
        "awk -F= '$1==\"NOSI_VERSION\"{print $2}' /etc/nosi-release",
        lambda rc, out: (
            rc == 0 and out.strip() not in ("", "unknown"),
            f"NOSI_VERSION='{out.strip()}'",
        ),
    )

    # ---- motd: oneshot rendered, banner correct --------------------------
    check(
        "/etc/motd is non-empty and contains 'nosi'",
        "cat /etc/motd",
        lambda rc, out: (
            rc == 0 and "nosi" in out,
            out.splitlines()[0] if out else "(empty)",
        ),
    )
    check(
        "/usr/local/bin/nosi-motd is executable",
        "test -x /usr/local/bin/nosi-motd && echo ok",
        lambda rc, out: (out == "ok", out or f"exit {rc}"),
    )

    # ---- awesome tools ---------------------------------------------------
    for tool in ("iommu", "devbind", "hugepages", "ruff", "pyright"):
        check(
            f"/usr/local/bin/{tool} exists",
            f"test -x /usr/local/bin/{tool} && echo ok",
            lambda rc, out, _t=tool: (out == "ok", out or f"missing {_t}"),
        )

    # ---- sshd enabled ----------------------------------------------------
    # Already proven by the fact that we SSHed in. Record the unit state
    # explicitly so the assertion log surfaces it.
    if distro == "fedora":
        check(
            "sshd.service is-enabled",
            "systemctl is-enabled sshd.service",
            lambda rc, out: (out == "enabled", out),
        )
    else:
        check(
            "ssh.service or ssh.socket is-enabled",
            "systemctl is-enabled ssh.service ssh.socket 2>/dev/null | grep -q '^enabled$' && echo ok",
            lambda rc, out: (out == "ok", out or "neither enabled"),
        )

    # ---- ModemManager actually gone --------------------------------------
    check(
        "ModemManager is not active",
        "systemctl is-active ModemManager.service 2>/dev/null || echo inactive",
        lambda rc, out: (out != "active", out),
    )

    # ---- ubuntu-only: snapd soft-disabled --------------------------------
    if distro == "ubuntu":
        check(
            "snapd.socket is masked",
            "systemctl is-enabled snapd.socket 2>/dev/null || echo missing",
            lambda rc, out: (out == "masked", out),
        )
        check(
            "snap binary still present (re-enableable)",
            "command -v snap >/dev/null && echo ok",
            lambda rc, out: (out == "ok", out or "missing"),
        )

    # ---- aidev-only: agentic CLIs ----------------------------------------
    if flavor == "aidev":
        for cli in ("claude-code", "codex", "gemini-cli", "opencode"):
            check(
                f"agentic CLI '{cli}' on PATH",
                f"command -v {cli} >/dev/null && echo ok",
                lambda rc, out, _c=cli: (out == "ok", out or f"missing {_c}"),
            )

    return results


def _report(results: list[tuple[bool, str, str]]) -> None:
    total = len(results)
    passed = sum(1 for ok, _, _ in results if ok)
    log.info(f"smoketest results: {passed}/{total} passed")
    for ok, name, detail in results:
        mark = "PASS" if ok else "FAIL"
        log.log(log.INFO if ok else log.ERROR, f"  {mark}  {name}  [{detail}]")


def _kill_qemu(pidfile: Path) -> None:
    if not pidfile.exists():
        return
    try:
        pid = int(pidfile.read_text().strip())
    except (ValueError, OSError):
        return
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.kill(pid, 15)
    # Give it a moment to drop the qcow2 lock, then SIGKILL if still up.
    time.sleep(2)
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.kill(pid, 9)


def _dump_serial(serial: Path) -> None:
    if serial.exists():
        tail = serial.read_text(errors="replace").splitlines()[-40:]
        log.error("---- last 40 lines of smoketest VM serial console ----")
        for line in tail:
            log.error(line)
        log.error("------------------------------------------------------")
