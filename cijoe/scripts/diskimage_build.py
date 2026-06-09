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
import json
import logging as log
import os
import re
from argparse import ArgumentParser
from pathlib import Path

from cijoe.core.misc import download
from cijoe.qemu.wrapper import Guest
from userdata_render import render as render_userdata

# Loadable nbd device used to expose the baked qcow2 as raw sectors for the
# post-bake shrink (same mechanism derive_pack uses for its chroot).
NBD_DEV = "/dev/nbd0"

# Bake-time disk size for the build VM. The cloud image grows to fill it, we
# install the nosi package set + upstream tools (plus a package_upgrade and, on
# Ubuntu, several initramfs/dracut regenerations and a secureboot cert), then
# trim caches. 12 GiB covers that transient peak: an 8 GiB disk ran the Ubuntu
# bake out of space mid-install. Keeping the flashed image small is done after
# the bake by shrinking the rootfs to fit, not by baking onto a small disk. The
# rootfs is expanded back to the operator's actual disk on first boot by
# nosi-growroot.service
# (provision/steps/09-growroot.sh), not by cloud-init's growpart (which never
# runs on a flashed bare-metal box: no datasource, so cloud-init self-disables;
# growpart covers only this build VM and datasource-backed cloud VMs).
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
    # qemu-img info dump that follows. Same problem as img_gz_pack.py.
    #
    # qemu-img writes the progress bar with carriage returns (\r) to
    # update in place; cijoe's --monitor / GHA's log capture both
    # line-buffer, so CR-only updates never flush and the operator sees
    # silence. Pipe through `tr` to convert each \r into \n so the buffer
    # flushes per progress tick. `set -o pipefail` keeps qemu-img's
    # non-zero exit visible despite the pipe; tr itself cannot fail on
    # this input.
    err, _ = cijoe.run_local(
        "bash -o pipefail -c "
        f'"qemu-img convert -p -O qcow2 -c {guest.boot_img} {disk_path} '
        "| tr '\\r' '\\n'\""
    )
    if err:
        log.error(f"Failed compacting image to {disk_path}")
        return err

    # Shrink the rootfs + partition to fit before the smoketest boots this same
    # qcow2, so a bad shrink fails CI loudly instead of shipping. ext4 only
    # (Debian/Ubuntu); btrfs/xfs roots are left untouched. nosi-growroot grows
    # it back on first boot.
    _shrink_qcow2(cijoe, disk_path)

    cijoe.run_local(f"qemu-img info {disk_path}")
    err, _ = cijoe.run_local(f"sha256sum {disk_path} > {disk_path}.sha256")
    if err:
        log.error("Failed computing sha256sum")
        return err

    return 0


def _shrink_qcow2(cijoe, qcow2: Path) -> None:
    """Shrink an ext4-rooted qcow2 in place: trim the filesystem to its used
    size (plus a margin), shrink its partition to match, cut the qcow2 virtual
    size down to the partition end, then relocate the GPT backup header to the
    new end (``sgdisk -e``) so the table stays valid. The bake runs on a roomy
    disk for headroom but ships compact; nosi-growroot expands it back on first
    boot.

    Cloud images are GPT, so the trailing backup GPT MUST be moved after the
    disk shrinks or the table is corrupt -- this is the one extra step over the
    Pi's MBR shrink. ext4 only: btrfs (Fedora) / xfs roots are left full-size.

    Safe degradation: every step up to the qcow2 resize bails out leaving the
    full image; past that point the smoketest boots this qcow2, so a botched
    table fails CI before anything is packed or published."""
    cijoe.run_local("sudo modprobe nbd max_part=8")
    cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")
    err, _ = cijoe.run_local(f"sudo qemu-nbd --connect={NBD_DEV} {qcow2}")
    if err:
        log.warning(f"shrink: qemu-nbd connect failed for {qcow2.name}; leaving full size")
        return
    new_bytes = None
    try:
        cijoe.run_local(f"sudo partprobe {NBD_DEV} >/dev/null 2>&1 || true")
        cijoe.run_local("sudo udevadm settle >/dev/null 2>&1 || true")
        root_part, fstype = _rootfs_part(cijoe)
        if not root_part:
            log.warning(f"shrink: no rootfs partition on {qcow2.name}; leaving full size")
            return
        if fstype != "ext4":
            log.info(f"shrink: {qcow2.name} root is {fstype}, not ext4; leaving full size")
            return
        partnum = root_part[len(NBD_DEV) :].lstrip("p")
        cijoe.run_local(f"sudo e2fsck -p -f {root_part} >/dev/null 2>&1 || true")
        est = _resize2fs_estimate(cijoe, root_part)
        if est is None:
            log.warning(f"shrink: cannot estimate fs min for {qcow2.name}; leaving full size")
            return
        target_blocks = est + 65536  # + 256 MiB headroom (4 KiB blocks)
        err, _ = cijoe.run_local(f"sudo resize2fs {root_part} {target_blocks} >/dev/null 2>&1")
        if err:
            log.warning(f"shrink: resize2fs failed for {qcow2.name}; leaving full size")
            return
        start = _partition_start_sector(cijoe, partnum)
        if start is None:
            log.warning(f"shrink: cannot read partition start for {qcow2.name}; leaving full size")
            return
        part_sectors = target_blocks * 8  # 4 KiB block = 8 x 512-byte sectors
        # Rewrite the partition's size, keeping its start (sfdisk -N).
        err, _ = cijoe.run_local(
            f"printf ',{part_sectors}\\n' | "
            f"sudo sfdisk -N {partnum} --no-reread -f {NBD_DEV} >/dev/null 2>&1"
        )
        if err:
            log.warning(f"shrink: sfdisk resize failed for {qcow2.name}; leaving full size")
            return
        # +1 MiB tail: room for the relocated backup GPT past the partition end.
        new_bytes = (start + part_sectors) * 512 + (1 << 20)
    finally:
        cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")
    if not new_bytes:
        return
    err, _ = cijoe.run_local(f"qemu-img resize --shrink {qcow2} {new_bytes}")
    if err:
        log.warning(f"shrink: qemu-img resize failed for {qcow2.name}; table may be oversized")
        return
    # The disk just got smaller; move the GPT backup to the new end + fix the
    # header's last-usable-LBA. sgdisk operates on the qcow2 via nbd, not the
    # container file directly.
    cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")
    err, _ = cijoe.run_local(f"sudo qemu-nbd --connect={NBD_DEV} {qcow2}")
    if err:
        log.warning(
            f"shrink: reconnect for GPT fixup failed on {qcow2.name}; smoketest will catch it"
        )
        return
    try:
        cijoe.run_local("sudo udevadm settle >/dev/null 2>&1 || true")
        cijoe.run_local(f"sudo sgdisk -e {NBD_DEV} >/dev/null 2>&1 || true")
        cijoe.run_local(f"sudo sgdisk -v {NBD_DEV} || true")
    finally:
        cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")
    log.info(f"shrink: {qcow2.name} -> {new_bytes // (1 << 20)} MiB")


def _rootfs_part(cijoe):
    """Return (device, fstype) for the largest rootfs-capable partition on
    NBD_DEV (the rootfs: /boot, ESP and BIOS-boot are smaller or other types)."""
    out_file = Path(f"/tmp/nosi-pack-lsblk-{os.getpid()}.json")
    try:
        cijoe.run_local(f"sudo lsblk -J -b -o NAME,FSTYPE,SIZE,TYPE {NBD_DEV} > {out_file}")
        try:
            data = json.loads(out_file.read_text()) if out_file.exists() else {}
        except (json.JSONDecodeError, OSError):
            data = {}
    finally:
        out_file.unlink(missing_ok=True)
    best = None
    for dev in data.get("blockdevices", []):
        for part in dev.get("children") or []:
            if part.get("type") != "part" or part.get("fstype") not in ("ext4", "btrfs", "xfs"):
                continue
            size = int(part.get("size") or 0)
            if best is None or size > best[0]:
                best = (size, part["name"], part.get("fstype"))
    if best:
        return f"/dev/{best[1]}", best[2]
    return None, None


def _resize2fs_estimate(cijoe, part: str) -> int | None:
    """`resize2fs -P` estimated minimum filesystem size, in fs blocks."""
    out_file = Path(f"/tmp/nosi-pack-resize-{os.getpid()}")
    try:
        cijoe.run_local(f"sudo resize2fs -P {part} > {out_file} 2>&1")
        text = out_file.read_text() if out_file.exists() else ""
    finally:
        out_file.unlink(missing_ok=True)
    m = re.search(r"[Ee]stimated minimum size of the filesystem:\s*(\d+)", text)
    return int(m.group(1)) if m else None


def _partition_start_sector(cijoe, partnum: str) -> int | None:
    """Start sector of partition <partnum> on NBD_DEV, parsed from `sfdisk -d`."""
    out_file = Path(f"/tmp/nosi-pack-sfdisk-{os.getpid()}")
    try:
        cijoe.run_local(f"sudo sfdisk -d {NBD_DEV} > {out_file} 2>/dev/null")
        text = out_file.read_text() if out_file.exists() else ""
    finally:
        out_file.unlink(missing_ok=True)
    for line in text.splitlines():
        if line.lstrip().startswith(f"{NBD_DEV}p{partnum} "):
            m = re.search(r"start=\s*(\d+)", line)
            if m:
                return int(m.group(1))
    return None


def _default_image_name(cijoe) -> str:
    nosi = cijoe.getconf("nosi", {})
    variant = nosi.get("variant", "debian-13-headless")
    return f"nosi-{variant}-x86_64"
