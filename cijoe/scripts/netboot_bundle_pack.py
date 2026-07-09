"""
Extract the ramboot netboot bundle from a baked headless nosi image
==================================================================

Runs after ``diskimage_build`` (specifically, after step
``34-netboot-ramboot-hook`` inside the guest has regenerated the
initrd with the bty ramboot attach-hook baked in). Attaches the
baked qcow2 via ``qemu-nbd`` (same mechanism ``derive_pack`` uses to
chroot into the rootfs), walks the partitions looking for the
``/boot`` filesystem (the one carrying ``vmlinuz-*`` +
``initrd.img-*`` or ``initramfs-*.img``), copies the newest kernel
+ its matching initrd out, and writes a manifest.

The bundle is what bty + nbdmux fetch at PXE-chain time: the image's
own kernel + initrd, produced at build time so runtime brittleness
(chroot regen on bty-server, apt/dnf mirror availability, gpg
timestamp drift) never enters the picture. See
PLAN-netboot-bundle.md for the full cross-repo sequencing.

Reads the new ``netboot`` section of
``system-imaging.images.<image_name>``:

  netboot.bundle_dir      output directory for vmlinuz+initrd+manifest
  netboot.source_disk_ref sibling disk-image OCI ref, recorded in manifest

Retargetable: False
"""

from __future__ import annotations

import errno
import hashlib
import json
import logging as log
import re
from argparse import ArgumentParser
from datetime import UTC, datetime
from pathlib import Path

from buildlib import default_image_name as _default_image_name

# ``qemu-nbd`` binds one qcow2 to /dev/nbd0. derive_pack.py uses the
# same convention; there is no reason to burn a second nbd slot when
# nothing else is attaching to nbd concurrently in the build task.
NBD_DEV = "/dev/nbd0"

# Match ``vmlinuz-<KVER>`` (Debian / Ubuntu / Fedora) but skip the
# ``vmlinuz`` symlink so we always pick the versioned file directly.
_KERNEL_RE = re.compile(r"^vmlinuz-([^/]+)$")

# initramfs-tools writes ``initrd.img-<KVER>``, dracut writes
# ``initramfs-<KVER>.img``; either shape yields KVER.
_INITRD_RES = (
    re.compile(r"^initrd\.img-([^/]+)$"),
    re.compile(r"^initramfs-([^/]+)\.img$"),
)


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Override the system-imaging image to pack. Defaults to "
        "nosi-<variant>-x86_64 (variant from [nosi] in the cijoe config).",
    )


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _find_boot_dir(mount_root: Path) -> tuple[Path, str]:
    """Search mounted partitions for /boot with a vmlinuz-* + initrd match.

    Returns (boot_dir_path, framework) where framework is
    ``initramfs-tools`` or ``dracut``. Raises FileNotFoundError if no
    partition holds a matching pair.
    """
    # Each subdir under mount_root is a partition mount. Some cloud images
    # (Debian) put /boot on the root partition; others (Ubuntu, Fedora)
    # use a separate /boot. Scan each candidate directory: the root
    # partition exposes /boot as a subdir; a separate boot partition IS
    # the boot filesystem, so its kernel files live at the mount root.
    for part_mount in sorted(mount_root.iterdir()):
        if not part_mount.is_dir():
            continue
        for candidate in (part_mount, part_mount / "boot"):
            if not candidate.is_dir():
                continue
            kernels: list[tuple[Path, str]] = []
            for p in candidate.iterdir():
                if not p.is_file():
                    continue
                km = _KERNEL_RE.match(p.name)
                if km is not None:
                    kernels.append((p, km.group(1)))
            if not kernels:
                continue
            # Pick the highest-versioned kernel: cloud images sometimes
            # leave the base-image kernel + a package-manager-installed
            # newer kernel side by side.
            kernels.sort(key=lambda t: t[1])
            _, kver = kernels[-1]
            for pattern in _INITRD_RES:
                for entry in candidate.iterdir():
                    im = pattern.match(entry.name)
                    if im is not None and im.group(1) == kver:
                        framework = (
                            "initramfs-tools" if pattern.pattern.startswith("^initrd") else "dracut"
                        )
                        return candidate, framework
    raise FileNotFoundError("no /boot with vmlinuz + matching initrd found in any partition")


def _connect_qemu_nbd(cijoe, qcow2_path: Path, mount_root: Path):
    """qemu-nbd --connect + partprobe + mount every partition RO."""
    # Preemptive disconnect in case a previous aborted run left the
    # device attached; same defensive pattern as derive_pack.
    cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")
    err, _ = cijoe.run_local(f"sudo qemu-nbd --connect={NBD_DEV} --read-only {qcow2_path}")
    if err:
        raise RuntimeError(f"qemu-nbd connect failed on {qcow2_path}")
    cijoe.run_local(f"sudo partprobe {NBD_DEV} >/dev/null 2>&1 || true")
    cijoe.run_local("sudo udevadm settle --timeout=10")

    mount_root.mkdir(parents=True, exist_ok=True)
    part_paths = sorted(Path("/dev").glob(f"{Path(NBD_DEV).name}p*"))
    for pn in part_paths:
        target = mount_root / pn.name
        target.mkdir(exist_ok=True)
        # Some partitions (BIOS boot, empty ESB-reserved) refuse to
        # mount cleanly; skip them silently. Only the /boot-carrying
        # one has to succeed for _find_boot_dir to return.
        cijoe.run_local(f"sudo mount -o ro {pn} {target}")


def _cleanup(cijoe, mount_root: Path):
    if mount_root.exists():
        for part_mount in sorted(mount_root.iterdir()):
            if part_mount.is_dir():
                cijoe.run_local(f"sudo umount {part_mount} 2>/dev/null || true")
    cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")


def main(args, cijoe):
    image_name = args.image_name or _default_image_name(cijoe)
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    netboot = image.get("netboot")
    if not netboot:
        # Not an error: images without a [netboot] section explicitly
        # opt out (wsl / lxc / docker never had a kernel to ship). Log
        # + return 0 so build.yaml can leave this step in for every
        # variant unconditionally.
        log.info(f"Image '{image_name}' has no [netboot] section; skipping")
        return 0

    disk = image.get("disk", {})
    qcow2_path = Path(disk["path"])
    bundle_dir = Path(netboot["bundle_dir"])
    source_disk_ref = netboot.get("source_disk_ref", "")

    if not qcow2_path.exists():
        log.error(f"Baked qcow2 not found: {qcow2_path}")
        return errno.ENOENT

    mount_root = qcow2_path.with_suffix(".netboot-mnt")
    try:
        _connect_qemu_nbd(cijoe, qcow2_path, mount_root)
        boot_dir, framework = _find_boot_dir(mount_root)
        log.info(f"Found /boot at {boot_dir}, framework={framework}")

        matched: list[tuple[Path, str]] = []
        for p in boot_dir.iterdir():
            m = _KERNEL_RE.match(p.name)
            if m is not None:
                matched.append((p, m.group(1)))
        matched.sort(key=lambda t: t[1])
        kernel_src, kver = matched[-1]

        if framework == "initramfs-tools":
            initrd_src = boot_dir / f"initrd.img-{kver}"
        else:
            initrd_src = boot_dir / f"initramfs-{kver}.img"

        bundle_dir.mkdir(parents=True, exist_ok=True)
        vmlinuz_out = bundle_dir / "vmlinuz"
        initrd_out = bundle_dir / "initrd"

        # ``sudo cp`` because the mount inherits the qcow2's UID/GID
        # via qemu-nbd (usually root). Restore ownership after so the
        # sha256 / manifest writes don't need sudo.
        err, _ = cijoe.run_local(f"sudo cp {kernel_src} {vmlinuz_out}")
        if err:
            return err
        err, _ = cijoe.run_local(f"sudo cp {initrd_src} {initrd_out}")
        if err:
            return err
        cijoe.run_local(f"sudo chown -R $(id -un):$(id -gn) {bundle_dir}")

        manifest = {
            "variant": image_name.replace("nosi-", "").rsplit("-", 1)[0],
            "arch": image_name.rsplit("-", 1)[-1],
            "built_at": datetime.now(UTC).isoformat(timespec="seconds"),
            "kernel_version": kver,
            "framework": framework,
            "source_disk_ref": source_disk_ref,
            "files": {
                "vmlinuz": {
                    "sha256": _sha256(vmlinuz_out),
                    "size": vmlinuz_out.stat().st_size,
                },
                "initrd": {
                    "sha256": _sha256(initrd_out),
                    "size": initrd_out.stat().st_size,
                },
            },
        }
        manifest_path = bundle_dir / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

        # Sidecar sha256s so ORAS consumers can verify each file
        # independently of the manifest.
        for name in ("vmlinuz", "initrd", "manifest.json"):
            f = bundle_dir / name
            (bundle_dir / f"{name}.sha256").write_text(f"{_sha256(f)}  {name}\n")

        log.info(
            f"Wrote netboot bundle to {bundle_dir}: "
            f"vmlinuz={vmlinuz_out.stat().st_size} bytes, "
            f"initrd={initrd_out.stat().st_size} bytes, "
            f"kver={kver}, framework={framework}"
        )
    finally:
        _cleanup(cijoe, mount_root)
        # Best-effort mount_root removal (empty dirs after umount).
        try:
            for d in sorted(mount_root.iterdir()):
                d.rmdir()
            mount_root.rmdir()
        except OSError:
            pass

    return 0
