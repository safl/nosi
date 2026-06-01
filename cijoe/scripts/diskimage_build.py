"""
Build a nosi base disk image from a cloud image
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
from userdata_render import render as render_userdata

# Bake-time disk size for the build VM. The cloud image grows to fill, we
# install the nosi package set (~1 GB), then trim caches. 12 GiB gives plenty
# of transient headroom for apt/dnf working space. The rootfs is expanded
# to the operator's actual disk on first boot by nosi-growroot.service
# (provision/steps/09-growroot.sh) -- NOT by cloud-init's growpart, which
# never runs on a flashed bare-metal box (no datasource => cloud-init
# disabled); cloud-init's growpart covers only this build VM and
# datasource-backed cloud VMs.
DISK_SIZE = "12G"


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Override the system-imaging image to build. Defaults to "
        "nosi-<variant>-x86_64 (variant from [nosi] in the cijoe config).",
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

    # FreeBSD VM images ship as xz-compressed raw disks
    # (FreeBSD-<ver>-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz) rather
    # than qcow2; convert to qcow2 once and cache the result alongside
    # the .raw.xz so subsequent bakes skip the decompress + convert.
    if cloud_image_path.name.endswith(".raw.xz"):
        cached_qcow2 = cloud_image_path.with_name(
            cloud_image_path.name[: -len(".raw.xz")] + ".qcow2"
        )
        if not cached_qcow2.exists():
            log.info(f"Converting {cloud_image_path.name} -> {cached_qcow2.name}")
            tmp_raw = cloud_image_path.with_suffix("")  # strip .xz, leave .raw
            err, _ = cijoe.run_local(f"xz -dkc {cloud_image_path} > {tmp_raw}")
            if err:
                log.error(f"Failed to xz-decompress {cloud_image_path}")
                return err
            err, _ = cijoe.run_local(f"qemu-img convert -O qcow2 {tmp_raw} {cached_qcow2}")
            tmp_raw.unlink(missing_ok=True)
            if err:
                log.error(f"Failed to convert {tmp_raw} -> {cached_qcow2}")
                return err
        cloud_image_path = cached_qcow2

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
    # Render the cloud-init template: replace the __NOSI_PROVISION_FILES__
    # marker (if present) with write_files: entries for every script under
    # provision/. Templates without the marker pass through unchanged so
    # variants that haven't been migrated yet keep working.
    provision_root = repo_root / "provision"
    try:
        rendered = render_userdata(userdata_path, provision_root)
    except Exception as exc:
        log.error(f"Failed rendering userdata {userdata_path}: {exc}")
        return errno.EIO
    guest_userdata.write_text(rendered)

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
    # `-p` (progress) so GHA logs see periodic percentage updates instead of
    # a silent multi-minute gap between the bake VM's poweroff and the
    # qemu-img info dump that follows. This is the same fix as
    # img_gz_publish.py applied here, where compaction of a 12 GiB qcow2
    # down to ~3 GiB is the silent step the operator sees as a hang.
    err, _ = cijoe.run_local(f"qemu-img convert -p -O qcow2 -c {guest.boot_img} {disk_path}")
    if err:
        log.error(f"Failed compacting image to {disk_path}")
        return err

    cijoe.run_local(f"qemu-img info {disk_path}")
    err, _ = cijoe.run_local(f"sha256sum {disk_path} > {disk_path}.sha256")
    if err:
        log.error("Failed computing sha256sum")
        return err

    return 0


def _default_image_name(cijoe) -> str:
    nosi = cijoe.getconf("nosi", {})
    variant = nosi.get("variant", "debian-13-headless")
    return f"nosi-{variant}-x86_64"
