"""
Build a csi base disk image from a cloud image
==============================================

Downloads the upstream cloud image (Debian / Ubuntu / Fedora), resizes the
boot disk so cloud-init has room to install our package list, builds the
NoCloud seed.iso, and boots QEMU. cloud-init runs the per-variant user-data
and powers off; the baked qcow2 is compacted via ``qemu-img convert -c`` and
checksummed.

Adapted from github.com/safl/bty's cijoe/scripts/diskimage_build.py. Path
resolution mirrors that project: cwd at run time is ``cijoe/`` (the Makefile
``cd``'s before invoking cijoe), so relative paths in the config resolve
against ``Path.cwd().parent`` (the repo root). Absolute paths (e.g.
``{{ local.env.HOME }}/...``) pass through unchanged.

Retargetable: False
"""

from __future__ import annotations

import errno
import logging as log
from argparse import ArgumentParser
from pathlib import Path

from cijoe.core.misc import download
from cijoe.qemu.wrapper import Guest


# Bake-time disk size for the build VM. The cloud image grows to fill, we
# install the csi package set (~1 GB), then trim caches. 12 GiB gives plenty
# of transient headroom for apt/dnf working space. cloud-init's growpart
# expands the rootfs to the operator's actual disk on first boot of the
# flashed instance.
DISK_SIZE = "12G"


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Override the system-imaging image to build. Defaults to "
        "csi-<variant>-x86_64 (variant from [csi] in the cijoe config).",
    )


def main(args, cijoe):
    image_name = args.image_name or _default_image_name(cijoe)
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    cloud = image.get("cloud", {})
    disk = image.get("disk", {})
    system_label = image.get("system_label")

    repo_root = Path.cwd().parent
    cloud_image_path = repo_root / cloud["path"]
    cloud_image_url = cloud["url"]
    metadata_path = repo_root / cloud["metadata_path"]
    userdata_path = repo_root / cloud["userdata_path"]

    if not cloud_image_path.exists():
        cloud_image_path.parent.mkdir(parents=True, exist_ok=True)
        err, _ = download(cloud_image_url, cloud_image_path)
        if err:
            log.error(f"Failed to download {cloud_image_url}")
            return err

    guest_name = None
    for name, guest_conf in cijoe.getconf("qemu.guests", {}).items():
        if guest_conf.get("system_label") == system_label:
            guest_name = name
            break

    if not guest_name:
        log.error(f"No qemu.guests entry found with system_label={system_label}")
        return errno.EINVAL

    guest = Guest(cijoe, cijoe.config, guest_name)
    guest.kill()
    guest.initialize(cloud_image_path)

    log.info(f"Resizing boot image to {DISK_SIZE}")
    err, _ = cijoe.run_local(f"qemu-img resize {guest.boot_img} {DISK_SIZE}")
    if err:
        log.error("Failed to resize boot image")
        return err

    guest_metadata = guest.guest_path / "meta-data"
    guest_userdata = guest.guest_path / "user-data"
    err, _ = cijoe.run_local(f"cp {metadata_path} {guest_metadata}")
    if err:
        log.error(f"Failed copying metadata {metadata_path} -> {guest_metadata}")
        return err
    err, _ = cijoe.run_local(f"cp {userdata_path} {guest_userdata}")
    if err:
        log.error(f"Failed copying userdata {userdata_path} -> {guest_userdata}")
        return err

    seed_img = guest.guest_path / "seed.img"
    mkisofs_cmd = " ".join(
        [
            "mkisofs",
            "-output",
            str(seed_img),
            "-volid",
            "cidata",
            "-joliet",
            "-rock",
            str(guest_userdata),
            str(guest_metadata),
        ]
    )
    err, _ = cijoe.run_local(mkisofs_cmd)
    if err:
        log.error("Failed creating seed ISO")
        return err

    err = guest.start(daemonize=False, extra_args=["-cdrom", str(seed_img)])
    if err:
        log.error("Cloud-init provisioning failed")
        return err

    disk_path = Path(disk["path"])
    disk_path.parent.mkdir(parents=True, exist_ok=True)
    log.info("Compacting image (qemu-img convert -c)")
    err, _ = cijoe.run_local(f"qemu-img convert -O qcow2 -c {guest.boot_img} {disk_path}")
    if err:
        log.error(f"Failed compacting image to {disk_path}")
        return err

    cijoe.run_local(f"qemu-img info {disk_path}")
    err, _ = cijoe.run_local(f"sha256sum {disk_path} > {disk_path}.sha256")
    if err:
        log.error("Failed computing sha256sum")
        return err

    cijoe.run_local(f"ls -la {disk_path}")
    cijoe.run_local(f"cat {disk_path}.sha256")

    return 0


def _default_image_name(cijoe) -> str:
    csi = cijoe.getconf("csi", {})
    variant = csi.get("variant", "debian-base")
    return f"csi-{variant}-x86_64"
