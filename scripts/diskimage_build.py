"""
Build a csi base disk image from a cloud image
==============================================

Downloads the upstream cloud image, resizes the boot disk so cloud-init has
room to install our package list, generates a NoCloud seed ISO with the
per-variant cloud-init user-data, boots QEMU with that seed (cloud-init runs
inside, then powers off), and snapshots the result to disk.path.

Adapted from the same pattern used by jellyfin-kiosk-appliance-builder.

Retargetable: False
"""
import errno
import logging as log
from argparse import ArgumentParser
from pathlib import Path

from cijoe.core.misc import download
from cijoe.qemu.wrapper import Guest


# Cloud images ship as ~2-3 GB sparse files. We grow them enough that the
# package set (~1 GB) plus mkfs slack fits comfortably.
DISK_SIZE = "12G"


def add_args(parser: ArgumentParser):
    parser.add_argument("--image_name", type=str, required=True)


def main(args, cijoe):
    image_name = args.image_name
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    cloud = image.get("cloud", {})
    disk = image.get("disk", {})
    system_label = image.get("system_label")

    cloud_image_path = Path(cloud["path"])
    cloud_image_url = cloud["url"]
    metadata_path = Path(cloud["metadata_path"])
    userdata_path = Path(cloud["userdata_path"])

    # Download cloud image if we don't already have it cached.
    if not cloud_image_path.exists():
        cloud_image_path.parent.mkdir(parents=True, exist_ok=True)
        err, _ = download(cloud_image_url, cloud_image_path)
        if err:
            log.error(f"Failed to download {cloud_image_url}")
            return err

    # Find a guest definition that matches this image's system_label.
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

    # Resize boot image so the in-guest package install doesn't run out of room.
    log.info(f"Resizing boot image to {DISK_SIZE}")
    err, _ = cijoe.run_local(f"qemu-img resize {guest.boot_img} {DISK_SIZE}")
    if err:
        log.error("Failed to resize boot image")
        return err

    # Stage seed files and build the NoCloud CIDATA ISO.
    guest_metadata = guest.guest_path / "meta-data"
    guest_userdata = guest.guest_path / "user-data"
    cijoe.run_local(f"cp {metadata_path} {guest_metadata}")
    cijoe.run_local(f"cp {userdata_path} {guest_userdata}")

    seed_img = guest.guest_path / "seed.img"
    mkisofs_cmd = " ".join([
        "mkisofs", "-output", str(seed_img),
        "-volid", "cidata", "-joliet", "-rock",
        str(guest_userdata), str(guest_metadata),
    ])
    err, _ = cijoe.run_local(mkisofs_cmd)
    if err:
        log.error("Failed creating seed ISO")
        return err

    # Boot. cloud-init runs, installs packages, finalises identity wipe, powers off.
    err = guest.start(daemonize=False, extra_args=["-cdrom", str(seed_img)])
    if err:
        log.error("Cloud-init provisioning failed")
        return err

    # Compact + checksum the baked image.
    disk_path = Path(disk["path"])
    disk_path.parent.mkdir(parents=True, exist_ok=True)
    log.info("Compacting image (qemu-img convert -c)")
    err, _ = cijoe.run_local(
        f"qemu-img convert -O qcow2 -c {guest.boot_img} {disk_path}"
    )
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
