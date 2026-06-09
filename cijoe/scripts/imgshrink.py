"""
Shrink a raw disk image to fit
==============================

Helper (not a runnable cijoe step) shared by ``img_gz_pack`` and
``derive_pack``: trim an ext4 rootfs + its partition in a raw ``.img`` down to
the used size (plus a margin), truncate the file, and relocate the GPT backup
header to the new end. The images bake on a roomy disk for provisioning
headroom but ship compact; nosi-growroot expands the rootfs back on first boot.

Why pack-time and not bake-time: ``derive_pack`` copies the baked base and
installs the derived shape's packages into it, so the base must stay roomy
until every derive has run. Shrinking each published raw artifact instead keeps
the base full for provisioning while still shipping small images.

Cloud images are GPT, whose backup header sits at the very end of the disk, so
truncating orphans it -- ``sgdisk -e`` moves it to the new end and fixes the
primary header's last-usable-LBA. MBR images (the Pi) need no such fixup; this
helper detects the table type and only touches GPT.

ext4 only: btrfs (Fedora) and xfs roots are left full-size with a log line.

Safe degradation: every step up to the truncate bails out leaving the image
untouched (full-size). After the truncate a GPT-verify failure returns an error
so the pack step fails loudly rather than shipping a broken table.
"""

from __future__ import annotations

import errno
import json
import logging as log
import os
import re
from pathlib import Path


def shrink_raw(cijoe, raw: Path) -> int:
    """Shrink ``raw`` in place. Returns 0 on success or safe no-op, an errno on
    a post-truncate GPT-verify failure (a corrupt table that must not ship)."""
    loopdev = _losetup(cijoe, raw)
    if not loopdev:
        log.warning(f"shrink: losetup failed for {raw.name}; leaving full size")
        return 0
    new_bytes = None
    pttype = None
    try:
        root_part, fstype, pttype = _rootfs(cijoe, loopdev)
        if not root_part:
            log.warning(f"shrink: no rootfs partition on {raw.name}; leaving full size")
            return 0
        if fstype != "ext4":
            log.info(f"shrink: {raw.name} root is {fstype}, not ext4; leaving full size")
            return 0
        partnum = root_part[len(loopdev) :].lstrip("p")
        cijoe.run_local(f"sudo e2fsck -p -f {root_part} >/dev/null 2>&1 || true")
        # Minimize to the true minimum (relocates blocks). resize2fs -P only
        # estimates and over-reports by gigabytes on these toolchain-heavy
        # images, so -M shrinks far more. Then grow back a small margin so the
        # rootfs has slack on the first boot before nosi-growroot expands it.
        min_blocks = _resize2fs_minimize(cijoe, root_part)
        if min_blocks is None:
            log.warning(f"shrink: minimize failed for {raw.name}; leaving full size")
            return 0
        target_blocks = min_blocks + 65536  # + 256 MiB slack (4 KiB blocks)
        err, _ = cijoe.run_local(f"sudo resize2fs {root_part} {target_blocks} >/dev/null 2>&1")
        if err:
            log.warning(f"shrink: resize2fs grow-back failed for {raw.name}; leaving full size")
            return 0
        start = _part_start(cijoe, loopdev, partnum)
        if start is None:
            log.warning(f"shrink: cannot read partition start for {raw.name}; leaving full size")
            return 0
        part_sectors = target_blocks * 8  # 4 KiB block = 8 x 512-byte sectors
        err, _ = cijoe.run_local(
            f"printf ',{part_sectors}\\n' | "
            f"sudo sfdisk -N {partnum} --no-reread -f {loopdev} >/dev/null 2>&1"
        )
        if err:
            log.warning(f"shrink: sfdisk resize failed for {raw.name}; leaving full size")
            return 0
        # +1 MiB tail: room for the relocated backup GPT past the partition end.
        new_bytes = (start + part_sectors) * 512 + (1 << 20)
    finally:
        cijoe.run_local(f"sudo losetup -d {loopdev} 2>/dev/null || true")
    if not new_bytes:
        return 0
    cijoe.run_local(f"truncate -s {new_bytes} {raw}")
    if pttype != "gpt":
        log.info(f"shrink: {raw.name} -> {new_bytes // (1 << 20)} MiB ({pttype} table)")
        return 0
    # The disk just got smaller; the backup GPT was at the old end. Relocate it
    # to the new end (sgdisk -e) and verify the table before letting it ship.
    rc = _fix_gpt_backup(cijoe, raw)
    if rc:
        log.error(f"shrink: {raw.name} GPT invalid after relocate; failing")
        return rc
    log.info(f"shrink: {raw.name} -> {new_bytes // (1 << 20)} MiB")
    return 0


def _fix_gpt_backup(cijoe, raw: Path) -> int:
    """Re-attach the truncated image, move the backup GPT to the new end, and
    verify. Returns 0 if the table is clean, errno.EIO otherwise."""
    loopdev = _losetup(cijoe, raw)
    if not loopdev:
        log.warning(f"shrink: re-attach for GPT fixup failed on {raw.name}")
        return errno.EIO
    out_file = Path(f"/tmp/nosi-shrink-sgdisk-{os.getpid()}")
    try:
        cijoe.run_local(f"sudo sgdisk -e {loopdev} >/dev/null 2>&1 || true")
        cijoe.run_local(f"sudo sgdisk -v {loopdev} > {out_file} 2>&1 || true")
        text = out_file.read_text() if out_file.exists() else ""
    finally:
        out_file.unlink(missing_ok=True)
        cijoe.run_local(f"sudo losetup -d {loopdev} 2>/dev/null || true")
    return 0 if "No problems found" in text else errno.EIO


def _losetup(cijoe, raw: Path) -> str | None:
    """Attach ``raw`` as a partitioned loop device; return its path."""
    out_file = raw.with_suffix(raw.suffix + ".loop")
    try:
        err, _ = cijoe.run_local(f"sudo losetup -fP --show {raw} > {out_file}")
        if err or not out_file.exists():
            return None
        lines = out_file.read_text().strip().splitlines()
        loopdev = lines[-1].strip() if lines else None
    finally:
        out_file.unlink(missing_ok=True)
    if loopdev:
        cijoe.run_local(f"sudo partprobe {loopdev} >/dev/null 2>&1 || true")
        cijoe.run_local("sudo udevadm settle >/dev/null 2>&1 || true")
    return loopdev


def _rootfs(cijoe, loopdev: str):
    """Return (device, fstype, pttype) for the largest rootfs-capable partition
    (the rootfs: /boot, ESP, BIOS-boot are smaller or other fstypes). pttype is
    the partition-table type of the whole device (gpt / dos)."""
    out_file = Path(f"/tmp/nosi-shrink-lsblk-{os.getpid()}.json")
    try:
        cijoe.run_local(f"sudo lsblk -J -b -o NAME,FSTYPE,SIZE,TYPE,PTTYPE {loopdev} > {out_file}")
        try:
            data = json.loads(out_file.read_text()) if out_file.exists() else {}
        except (json.JSONDecodeError, OSError):
            data = {}
    finally:
        out_file.unlink(missing_ok=True)
    best = None
    pttype = None
    for dev in data.get("blockdevices", []):
        pttype = dev.get("pttype") or pttype
        for part in dev.get("children") or []:
            if part.get("type") != "part" or part.get("fstype") not in ("ext4", "btrfs", "xfs"):
                continue
            pttype = part.get("pttype") or pttype
            size = int(part.get("size") or 0)
            if best is None or size > best[0]:
                best = (size, part["name"], part.get("fstype"))
    if best:
        return f"/dev/{best[1]}", best[2], pttype
    return None, None, pttype


def _resize2fs_minimize(cijoe, part: str) -> int | None:
    """Shrink the fs to its minimum (`resize2fs -M`) and return the resulting
    size in fs blocks, parsed from resize2fs's `is now/already <N> (Nk) blocks
    long`. Falls back to the conservative `-P` estimate if the line is absent."""
    out_file = Path(f"/tmp/nosi-shrink-resize-{os.getpid()}")
    try:
        cijoe.run_local(f"sudo resize2fs -M {part} > {out_file} 2>&1")
        text = out_file.read_text() if out_file.exists() else ""
    finally:
        out_file.unlink(missing_ok=True)
    m = re.search(r"(?:now|already) (\d+) \(\d+k\) blocks long", text)
    if m:
        return int(m.group(1))
    m = re.search(r"[Ee]stimated minimum size of the filesystem:\s*(\d+)", text)
    return int(m.group(1)) if m else None


def _part_start(cijoe, loopdev: str, partnum: str) -> int | None:
    """Start sector of partition <partnum>, parsed from `sfdisk -d`."""
    out_file = Path(f"/tmp/nosi-shrink-sfdisk-{os.getpid()}")
    try:
        cijoe.run_local(f"sudo sfdisk -d {loopdev} > {out_file} 2>/dev/null")
        text = out_file.read_text() if out_file.exists() else ""
    finally:
        out_file.unlink(missing_ok=True)
    for line in text.splitlines():
        if line.lstrip().startswith(f"{loopdev}p{partnum} "):
            m = re.search(r"start=\s*(\d+)", line)
            if m:
                return int(m.group(1))
    return None
