"""
Offline smoketest for a baked nosi Raspberry Pi (arm64) image
=============================================================

``image_smoketest.py`` boots the baked x86 qcow2 in
``qemu-system-x86_64 -machine q35`` and asserts over SSH. A Raspberry Pi OS
image does NOT boot in a generic QEMU ``virt`` machine (it wants the Pi
firmware + Foundation kernel), so this is an *offline* smoketest instead: it
loop-mounts the raw ``.img`` read-only and asserts the on-disk invariants that
prove apply.sh ran end-to-end.

What this covers vs. the x86 smoketest:
  * identity / sentinel / metadata files, operator account, tool binaries,
    root-lock, sshd drop-in + the keygen oneshot being enabled -- all checked
    from the filesystem, so a step that silently no-op'd is caught.
  * NOT covered: a live boot. There is no SSH/runtime assertion here, so a
    binary that is present-but-broken or a unit that fails only at boot is not
    caught. A real-Pi CI runner that flashes + boots is the follow-up that
    closes that gap (see the handoff / PR).

Reads the raw ``.img`` from ``disk.path`` of the configured image (the build
step leaves it uncompressed for exactly this). Mount + partition discovery is
shared with ``rpi_image_build``.

Retargetable: False
"""

from __future__ import annotations

import errno
import json
import logging as log
import os
from argparse import ArgumentParser
from pathlib import Path

from rpi_image_build import _losetup_attach, _partitions, _resolve_path, target_images


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Smoketest only this image. Defaults to the base + all its derives (the full Pi set).",
    )


def main(args, cijoe):
    images = cijoe.getconf("system-imaging.images", {})
    if args.image_name:
        image = images.get(args.image_name)
        if not image:
            log.error(f"Image '{args.image_name}' not found in config")
            return errno.EINVAL
        variant = args.image_name[len("nosi-") : -len("-arm64")]
        targets = [(args.image_name, image, variant)]
    else:
        targets = target_images(cijoe)
    if not targets:
        log.error("no Pi images resolved from config")
        return errno.EINVAL

    repo_root = Path.cwd().parent
    rc = 0
    for image_name, image, variant in targets:
        if _smoke_one(cijoe, repo_root, image_name, image, variant):
            rc = errno.EINVAL
    return rc


def _smoke_one(cijoe, repo_root: Path, image_name: str, image: dict, variant: str) -> bool:
    """Smoketest one image. Returns True on failure."""
    img = _resolve_path(repo_root, image["disk"]["path"])
    if not img.exists():
        log.error(f"{image_name}: baked image not found: {img}")
        return True

    mnt = Path(f"/mnt/nosi-rpi-smoke-{os.getpid()}")
    cleanup: list[str] = []
    failures: list[str] = []
    try:
        loopdev = _losetup_attach(cijoe, img)
        if not loopdev:
            log.error(f"{image_name}: losetup failed")
            return True
        cleanup.append(f"sudo losetup -d {loopdev} 2>/dev/null || true")
        cijoe.run_local(f"sudo partprobe {loopdev} >/dev/null 2>&1 || true")

        root_part, _ = _partitions(cijoe, loopdev)
        if not root_part:
            log.error(f"{image_name}: no ext4 root partition found")
            return True

        cijoe.run_local(f"sudo mkdir -p {mnt}")
        err, _ = cijoe.run_local(f"sudo mount -o ro {root_part} {mnt}")
        if err:
            log.error(f"{image_name}: mount {root_part} failed")
            return True
        # cleanup runs in reverse: append rmdir before the umount it depends on.
        cleanup.append(f"sudo rmdir {mnt} 2>/dev/null || true")
        cleanup.append(f"sudo umount {mnt} 2>/dev/null || true")

        _run_checks(cijoe, mnt, variant, failures)
    finally:
        for cmd in reversed(cleanup):
            cijoe.run_local(cmd)

    if failures:
        log.error(f"smoketest FAILED for {image_name} ({len(failures)} check(s)):")
        for f in failures:
            log.error(f"  - {f}")
        return True
    log.info(f"smoketest OK for {image_name}")
    return False


def _run_checks(cijoe, mnt: Path, variant: str, failures: list[str]) -> None:
    # ---- apply.sh ran to completion (sentinel) ----------------------------
    if not _exists(cijoe, mnt / "etc/nosi/apply-ok"):
        failures.append("/etc/nosi/apply-ok sentinel missing (apply.sh did not finish)")

    # ---- identity ---------------------------------------------------------
    release = _read(cijoe, mnt / "etc/nosi-release")
    if release is None:
        failures.append("/etc/nosi-release missing")
    else:
        if f"NOSI_VARIANT={variant}" not in release:
            failures.append(f"/etc/nosi-release does not carry NOSI_VARIANT={variant}")
        if "NOSI_VERSION=unknown" in release or "NOSI_VERSION=" not in release:
            failures.append("/etc/nosi-release has no concrete NOSI_VERSION")

    meta = _read(cijoe, mnt / "etc/nosi-metadata.json")
    if meta is None:
        failures.append("/etc/nosi-metadata.json missing")
    else:
        try:
            json.loads(meta)
        except json.JSONDecodeError:
            failures.append("/etc/nosi-metadata.json does not parse as JSON")

    # ---- operator account + root lock -------------------------------------
    passwd = _read(cijoe, mnt / "etc/passwd") or ""
    if "\nodus:" not in ("\n" + passwd):
        failures.append("operator account 'odus' missing from /etc/passwd")
    shadow = _read(cijoe, mnt / "etc/shadow") or ""
    root_hash = next(
        (line.split(":")[1] for line in shadow.splitlines() if line.startswith("root:")),
        "",
    )
    if shadow and root_hash[:1] not in ("!", "*"):
        failures.append("root account is not locked in /etc/shadow")

    # ---- motd renderer ----------------------------------------------------
    if not _exists(cijoe, mnt / "usr/local/bin/nosi-motd"):
        failures.append("/usr/local/bin/nosi-motd missing")

    # ---- sshd config + keygen oneshot enabled -----------------------------
    if not _exists(cijoe, mnt / "etc/ssh/sshd_config.d/00-nosi.conf"):
        failures.append("/etc/ssh/sshd_config.d/00-nosi.conf missing (step 28)")
    if not _exists(
        cijoe, mnt / "etc/systemd/system/multi-user.target.wants/nosi-sshd-keygen.service"
    ):
        failures.append("nosi-sshd-keygen.service not enabled (step 28)")

    # ---- upstream tool binaries (step 20) ---------------------------------
    tools = (
        "hx",
        "uv",
        "uvx",
        "zellij",
        "lazygit",
        "yazi",
        "taplo",
        "marksman",
        "oras",
        "zig",
        "zls",
        "tailscale",
    )
    failures.extend(
        f"upstream tool /usr/local/bin/{t} missing"
        for t in tools
        if not _exists(cijoe, mnt / "usr/local/bin" / t)
    )

    # ---- vpn baseline: wg present, tailscaled installed but DORMANT --------
    # The dormant contract (no idle daemon, no pre-auth logtail) shows up
    # offline as the absence of the multi-user.target.wants/ enable link.
    if not _exists(cijoe, mnt / "usr/bin/wg"):
        failures.append("/usr/bin/wg missing (wireguard-tools baseline package)")
    if not _exists(cijoe, mnt / "usr/local/sbin/tailscaled"):
        failures.append("/usr/local/sbin/tailscaled missing (step 20)")
    if _exists(cijoe, mnt / "etc/systemd/system/multi-user.target.wants/tailscaled.service"):
        failures.append("tailscaled.service is enabled (must ship dormant)")

    # ---- arm64 guards held (x86-only steps must NOT have run) --------------
    if _exists(cijoe, mnt / "etc/modprobe.d/nosi-r8125.conf"):
        failures.append("step 10 r8125 ran on arm64 (modprobe.d softdep present)")

    # ---- desktop shape extras ---------------------------------------------
    if variant.endswith("-desktop"):
        if not _exists(cijoe, mnt / "etc/greetd/config.toml"):
            failures.append("desktop: /etc/greetd/config.toml missing (step 50)")
        if not _exists(cijoe, mnt / "usr/bin/sway"):
            failures.append("desktop: /usr/bin/sway missing (step 50)")
        # greetd is a display manager: enabling it registers
        # display-manager.service (alias), not a multi-user.target.wants link.
        if not _exists(cijoe, mnt / "etc/systemd/system/display-manager.service"):
            failures.append("desktop: greetd not enabled as display-manager (step 50)")


def _exists(cijoe, path: Path) -> bool:
    """Probe a path in the (root-owned) mounted rootfs. `test -e` follows
    symlinks, and an absolute symlink inside the image (e.g.
    /usr/local/bin/zig -> /usr/local/zig/zig, or a *.target.wants/ unit link
    -> /etc/systemd/system/...) resolves against the HOST fs and looks
    missing, so accept the symlink itself via `test -L` too."""
    err, _ = cijoe.run_local(f"sudo test -e {path}")
    if err == 0:
        return True
    err, _ = cijoe.run_local(f"sudo test -L {path}")
    return err == 0


def _read(cijoe, path: Path) -> str | None:
    """Read a (possibly root-owned) file from the mounted rootfs via a temp
    copy, since the smoketest process is not root."""
    if not _exists(cijoe, path):
        return None
    tmp = Path(f"/tmp/nosi-rpi-smoke-read-{os.getpid()}")
    try:
        err, _ = cijoe.run_local(f"sudo cp {path} {tmp} && sudo chown $(id -u):$(id -g) {tmp}")
        if err:
            return None
        return tmp.read_text(errors="replace")
    finally:
        tmp.unlink(missing_ok=True)
