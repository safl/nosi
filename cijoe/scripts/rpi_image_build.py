"""
Build a nosi Raspberry Pi (arm64) image from the official Raspberry Pi OS
========================================================================

The x86 nosi variants bake by booting an upstream cloud image in QEMU and
letting cloud-init run apply.sh (``diskimage_build.py``). That model does not
work for the Raspberry Pi: Pi-targeted images boot via the VideoCore firmware
+ ``config.txt``/``cmdline.txt`` chain, not a generic QEMU ``virt`` machine,
so they cannot be booted on a hosted runner.

Instead this script customizes the official **Raspberry Pi OS Lite (arm64)**
image in place -- the same loop-mount + chroot mechanism ``derive_pack.py``
uses for the x86 shape derives -- so the result keeps the Foundation kernel /
firmware / bootloader and flashes straight to SD/USB:

  1. download + ``xz -d`` the pinned Raspberry Pi OS ``.img.xz`` (cached),
  2. copy it to the working disk path and grow the ext4 root for headroom,
  3. ``losetup -P`` + mount root (+ the FAT firmware partition), bind
     /dev /proc /sys /run + the host resolv.conf,
  4. drop the provision/ tree + ``.nosi-version`` into /opt/nosi,
  5. ``apt-get install`` the curated base package set (the chroot build is
     the Pi's delivery mechanism -- cloud-init never runs -- so it owns the
     ``packages:`` install the .user files own elsewhere),
  6. run ``apply.sh <variant>`` (full base run),
  7. neutralize Raspberry Pi OS's first-boot wizard + strip per-instance
     identity (ssh host keys, machine-id), then unmount.

Each ``[[...derive]]`` entry (the desktop shape) repeats steps 2-7 from a copy
of the baked headless ``.img``, running ``apply.sh <variant> --shape-only``
so only the shape step (50-desktop-stack's apt Sway branch) runs.

Output is a raw ``.img`` per image at its ``disk.path`` (NOT gzipped here, so
``rpi_image_smoketest`` can loop-mount it before ``img_gz_pack`` -- with
``publish.from_raw`` -- compresses it).

Runs natively on an arm64 host/runner (no qemu-user emulation); on an x86 host
it needs binfmt + qemu-user-static registered so the chroot's arm64 binaries
execute.

Path resolution mirrors the other cijoe scripts: cwd is ``cijoe/`` at run
time, so relative config paths resolve against ``Path.cwd().parent`` (repo
root); absolute / ``{{ local.env.HOME }}`` paths pass through.

stdout capture follows derive_pack's pattern (redirect to a temp file and
read it) rather than the second value of ``run_local``, which the cijoe
scripts in this repo never consume for output.

Retargetable: False
"""

from __future__ import annotations

import errno
import json
import logging as log
import os
from argparse import ArgumentParser
from pathlib import Path

from buildlib import q as _q
from cijoe.core.misc import download
from imgshrink import losetup_attach as _losetup_attach
from imgshrink import shrink_raw
from userdata_render import _resolve_version


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Override the system-imaging image to build. Defaults to "
        "nosi-<variant>-arm64 (variant from [nosi] in the cijoe config).",
    )


def main(args, cijoe):
    image_name = args.image_name or _default_image_name(cijoe)
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    repo_root = Path.cwd().parent
    version = _resolve_version(repo_root)
    log.info(f"{image_name}: build version {version}")

    # ---- 1. obtain a decompressed base image (cached) ---------------------
    base_img = _fetch_base_image(cijoe, repo_root, image)
    if base_img is None:
        return errno.EIO

    # ---- 2. bake the headless base ----------------------------------------
    disk_path = _resolve_path(repo_root, image["disk"]["path"])
    rc = _bake_one(
        cijoe,
        repo_root,
        src_img=base_img,
        dst_img=disk_path,
        variant=cijoe.getconf("nosi", {}).get("variant"),
        grow=image.get("grow", "8G"),
        packages_path=_resolve_path(repo_root, image["cloud"]["packages_path"]),
        version=version,
        shape_only=False,
    )
    if rc:
        return rc
    shrink_raw(cijoe, disk_path)

    # ---- 3. derived shapes (desktop) from the baked headless .img ----------
    for entry in image.get("derive", []) or []:
        d_variant = entry["variant"]
        d_name = f"nosi-{d_variant}-arm64"
        d_image = images.get(d_name)
        if not d_image:
            log.error(f"derive '{d_variant}': no image entry '{d_name}' in config")
            return errno.EINVAL
        d_disk = _resolve_path(repo_root, d_image["disk"]["path"])
        log.info(f"derive: {d_variant} (shape-only) -> {d_disk}")
        rc = _bake_one(
            cijoe,
            repo_root,
            src_img=disk_path,  # copy of the baked headless image
            dst_img=d_disk,
            variant=d_variant,
            grow=d_image.get("grow", "8G"),  # grow for the desktop install
            packages_path=None,  # shape step owns its own installs
            version=version,
            shape_only=True,
        )
        if rc:
            return rc
        shrink_raw(cijoe, d_disk)

    return 0


# ---------------------------------------------------------------------------
# base image acquisition
# ---------------------------------------------------------------------------


def _fetch_base_image(cijoe, repo_root: Path, image: dict) -> Path | None:
    """Download the Raspberry Pi OS ``.img.xz`` (cached) and return a path to
    a decompressed ``.img`` (also cached next to it, like the FreeBSD .raw.xz
    handling in diskimage_build)."""
    cloud = image["cloud"]
    xz_path = _resolve_path(repo_root, cloud["path"])
    if not xz_path.exists():
        xz_path.parent.mkdir(parents=True, exist_ok=True)
        err, _ = download(cloud["url"], xz_path)
        if err:
            log.error(f"Failed to download {cloud['url']}")
            return None

    if not xz_path.name.endswith(".img.xz"):
        log.error(f"expected a .img.xz base image, got {xz_path.name}")
        return None

    img_path = xz_path.with_name(xz_path.name[: -len(".xz")])  # strip .xz
    if not img_path.exists():
        log.info(f"Decompressing {xz_path.name} -> {img_path.name}")
        err, _ = cijoe.run_local(f"xz -dkc {xz_path} > {img_path}")
        if err:
            log.error(f"Failed to xz-decompress {xz_path}")
            img_path.unlink(missing_ok=True)
            return None
    return img_path


# ---------------------------------------------------------------------------
# bake one image (base full-run, or derive shape-only)
# ---------------------------------------------------------------------------


def _bake_one(
    cijoe,
    repo_root: Path,
    src_img: Path,
    dst_img: Path,
    variant: str,
    grow: str | None,
    packages_path: Path | None,
    version: str,
    shape_only: bool,
) -> int:
    dst_img.parent.mkdir(parents=True, exist_ok=True)
    err, _ = cijoe.run_local(f"cp -f --reflink=auto {src_img} {dst_img}")
    if err:
        log.error(f"failed copying base image -> {dst_img}")
        return err

    # Grow the backing file BEFORE attaching so the loop device sees the new
    # size; the partition + filesystem are expanded on the live loop device
    # below. Done in one attach (not a separate grow+detach+reattach) so we
    # never race the second udev partition-scan.
    if grow:
        err, _ = cijoe.run_local(f"truncate -s +{grow} {dst_img}")
        if err:
            log.error("truncate (grow image) failed")
            return err

    mnt = Path(f"/mnt/nosi-rpi-{variant}-{os.getpid()}")
    cleanup: list[str] = []
    try:
        loopdev = _losetup_attach(cijoe, dst_img)
        if not loopdev:
            log.error("losetup failed")
            return errno.EIO
        cleanup.append(f"sudo losetup -d {loopdev} 2>/dev/null || true")

        root_part, boot_part = _partitions(cijoe, loopdev)
        if not root_part:
            log.error(f"no ext4 root partition found on {loopdev}")
            return errno.ENODEV

        if grow:
            rc = _grow_partition(cijoe, loopdev, root_part)
            if rc:
                return rc

        cijoe.run_local(f"sudo mkdir -p {mnt}")
        err, _ = cijoe.run_local(f"sudo mount {root_part} {mnt}")
        if err:
            log.error(f"mount {root_part} failed")
            return err
        # cleanup runs in reverse, so append rmdir BEFORE the umount that must
        # run before it (umount -R also catches the nested boot/firmware mount).
        cleanup.append(f"sudo rmdir {mnt} 2>/dev/null || true")
        cleanup.append(f"sudo umount -R {mnt} 2>/dev/null || true")

        # Raspberry Pi OS mounts the FAT firmware partition at /boot/firmware;
        # mount it so kernel/initramfs postinst hooks (e.g. update-initramfs
        # from step 15) write where the running Pi expects them.
        if boot_part:
            cijoe.run_local(f"sudo mkdir -p {mnt}/boot/firmware")
            err, _ = cijoe.run_local(f"sudo mount {boot_part} {mnt}/boot/firmware")
            if err:
                log.error(f"mount {boot_part} (boot/firmware) failed")
                return err

        for sub in ("dev", "proc", "sys", "run"):
            err, _ = cijoe.run_local(f"sudo mount --bind /{sub} {mnt}/{sub}")
            if err:
                log.error(f"bind-mount {sub} failed")
                return err
            cleanup.append(f"sudo umount {mnt}/{sub} 2>/dev/null || true")
        # /dev is a non-recursive bind, so the host's devpts submount is not
        # carried in; mount a fresh one so apt + maintainer scripts have ptys
        # (otherwise apt logs "Can not write log (Is /dev/pts mounted?)").
        cijoe.run_local(f"sudo mount -t devpts devpts {mnt}/dev/pts 2>/dev/null || true")
        cleanup.append(f"sudo umount {mnt}/dev/pts 2>/dev/null || true")
        err, _ = cijoe.run_local(f"sudo mount --bind /etc/resolv.conf {mnt}/etc/resolv.conf")
        if err:
            log.error("bind-mount /etc/resolv.conf failed")
            return err
        cleanup.append(f"sudo umount {mnt}/etc/resolv.conf 2>/dev/null || true")

        rc = _provision(cijoe, repo_root, mnt, variant, packages_path, version, shape_only)
        if rc:
            return rc

        # Export the baked metadata.json for the ORAS annotations (mirrors the
        # x86 smoketest / derive_pack exporting nosi-<variant>.metadata.json).
        meta_dst = dst_img.with_suffix(".metadata.json")
        cijoe.run_local(
            f"sudo cp {mnt}/etc/nosi-metadata.json {meta_dst} && "
            f"sudo chown $(id -u):$(id -g) {meta_dst}"
        )

        _finalize_image(cijoe, mnt)
        return 0
    finally:
        for cmd in reversed(cleanup):
            cijoe.run_local(cmd)


def _provision(
    cijoe,
    repo_root: Path,
    mnt: Path,
    variant: str,
    packages_path: Path | None,
    version: str,
    shape_only: bool,
) -> int:
    if not shape_only:
        # Deliver the provision tree + build identity (the chroot build's
        # equivalent of cloud-init's write_files: + userdata_render).
        cijoe.run_local(f"sudo mkdir -p {mnt}/opt/nosi")
        err, _ = cijoe.run_local(f"sudo cp -a {repo_root}/provision {mnt}/opt/nosi/provision")
        if err:
            log.error("copying provision/ tree into the image failed")
            return err
        _write_root_file(cijoe, mnt / "opt/nosi/.nosi-version", f"{version}\n", "0644")

        # Free UID 1000 for the nosi operator: Raspberry Pi OS ships a default
        # user there, so step 04's `useradd -u 1000 odus` would fail with
        # "UID 1000 is not unique". First capture that user's supplementary
        # groups (the Pi hardware-access set: gpio, i2c, spi, dialout, video,
        # render, audio, bluetooth, ...) to a file so odus can adopt them
        # after apply.sh creates it; then remove the user + its home (the Lite
        # home holds only skel dotfiles, nothing Pi-specific). Mirrors the
        # `userdel` the x86 .user files do in bootcmd.
        free_uid = (
            "u=$(getent passwd 1000 | cut -d: -f1); "
            'if [ -n "$u" ] && [ "$u" != odus ]; then '
            'id -nG "$u" 2>/dev/null | tr " " "\\n" | grep -vxF "$u" '
            "> /opt/nosi/.rpi-operator-groups || true; "
            'userdel -r "$u" 2>/dev/null || true; '
            "fi; true"
        )
        cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q(free_uid)}")

    # Fresh apt index for the package + shape installs.
    err, _ = cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q('apt-get update')}")
    if err:
        log.error("chroot apt-get update failed")
        return err

    if packages_path is not None:
        pkgs = _read_packages(packages_path)
        if not pkgs:
            log.error(f"no packages parsed from {packages_path}")
            return errno.EINVAL
        install = (
            "DEBIAN_FRONTEND=noninteractive apt-get install -y "
            "--no-install-recommends " + " ".join(pkgs)
        )
        err, _ = cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q(install)}")
        if err:
            log.error("chroot base package install failed")
            return err

    flag = " --shape-only" if shape_only else ""
    apply_cmd = f"/opt/nosi/provision/apply.sh {variant}{flag}"
    err, _ = cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q(apply_cmd)}")
    if err:
        log.error(f"chroot apply.sh {variant}{flag} failed")
        return err

    if not shape_only:
        # Hand the removed Pi default user's hardware-access groups to odus
        # (created by apply.sh step 04), so GPIO / I2C / SPI / serial / camera
        # work without sudo, the way Raspberry Pi OS intends for its operator.
        adopt = (
            "if [ -f /opt/nosi/.rpi-operator-groups ] && id odus >/dev/null 2>&1; then "
            "for g in $(cat /opt/nosi/.rpi-operator-groups); do "
            'getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" odus || true; '
            "done; rm -f /opt/nosi/.rpi-operator-groups; fi; true"
        )
        cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q(adopt)}")
    return 0


def _finalize_image(cijoe, mnt: Path) -> None:
    """Neutralize Raspberry Pi OS first-boot wizard, strip per-instance
    identity, and clean caches. Mirrors the .user runcmd cleanup the x86
    variants do at the end of cloud-init."""
    # Raspberry Pi OS ships a first-boot user-creation wizard (userconfig
    # service / the cancel-rename flow) that assumes no interactive user
    # exists. apply.sh's step 04 already created `odus`, so mask the wizard
    # and restore a normal getty so the headless box boots straight to login.
    wizard = (
        "systemctl mask userconfig.service 2>/dev/null || true; "
        "systemctl disable userconfig.service 2>/dev/null || true; "
        "rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null || true; "
        "systemctl enable getty@tty1.service 2>/dev/null || true"
    )
    cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q(wizard)}")

    # Per-instance identity regenerates on first boot (step 28 ships the
    # ssh-keygen oneshot). Strip the baked host keys + machine-id so two
    # flashes of the same image are not SSH-fingerprint twins. Then drop the
    # apt index + caches the bake leaves behind.
    strip = (
        "rm -f /etc/ssh/ssh_host_*; "
        ": > /etc/machine-id; "
        "rm -f /var/lib/dbus/machine-id; "
        "apt-get clean; "
        "rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache /home/*/.cache"
    )
    cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q(strip)}")

    # Clock-floor: touch /usr/lib/clock-epoch so PID-1 systemd uses the bake
    # time as the boot-time clock floor (same rationale as the x86 .user).
    cijoe.run_local(f"sudo touch {mnt}/usr/lib/clock-epoch 2>/dev/null || true")


# ---------------------------------------------------------------------------
# disk + partition helpers
# ---------------------------------------------------------------------------


def _grow_partition(cijoe, loopdev: str, root_part: str) -> int:
    """Expand the ext4 root partition + filesystem to fill the (already
    grown) backing file. Operates on the live loop device, no reattach."""
    partnum = root_part[len(loopdev) :].lstrip("p")
    # growpart extends the partition to fill the freed space; resize2fs then
    # grows the ext4 fs. e2fsck first (resize2fs refuses a dirty fs).
    cijoe.run_local(f"sudo growpart {loopdev} {partnum}")
    cijoe.run_local(f"sudo partprobe {loopdev} >/dev/null 2>&1 || true")
    cijoe.run_local("sudo udevadm settle >/dev/null 2>&1 || true")
    cijoe.run_local(f"sudo e2fsck -p -f {root_part} || true")
    err, _ = cijoe.run_local(f"sudo resize2fs {root_part}")
    if err:
        log.error("resize2fs failed")
        return err
    return 0


def _partitions(cijoe, loopdev: str, attempts: int = 10):
    """Return (root_part, boot_part): the largest ext4 partition (rootfs)
    and the FAT partition (Raspberry Pi firmware), as /dev paths.

    Retries because the partition nodes can lag the loop attach even after
    partprobe + udevadm settle (mirrors derive_pack._find_rootfs_partition)."""
    out_file = Path(f"/tmp/nosi-rpi-lsblk-{os.getpid()}.json")
    for attempt in range(attempts):
        try:
            err, _ = cijoe.run_local(
                f"sudo lsblk -J -b -o NAME,FSTYPE,SIZE,TYPE {loopdev} > {out_file}"
            )
            data = {}
            if err == 0 and out_file.exists():
                try:
                    data = json.loads(out_file.read_text())
                except (json.JSONDecodeError, OSError):
                    data = {}
        finally:
            out_file.unlink(missing_ok=True)

        root = None  # (size, name)
        boot = None
        for dev in data.get("blockdevices", []):
            for part in dev.get("children") or []:
                if part.get("type") != "part":
                    continue
                fstype = part.get("fstype")
                name = part.get("name")
                size = int(part.get("size") or 0)
                if fstype in ("ext4", "ext3", "ext2") and (root is None or size > root[0]):
                    root = (size, name)
                elif fstype in ("vfat", "fat", "fat32") and boot is None:
                    boot = name
        if root:
            root_part = f"/dev/{root[1]}"
            boot_part = f"/dev/{boot}" if boot else None
            return root_part, boot_part
        if attempt < attempts - 1:
            cijoe.run_local("sleep 1")
    return None, None


def _read_packages(path: Path) -> list[str]:
    """Parse a package manifest: one package per line, blank lines and
    `#` comments ignored."""
    pkgs = []
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            pkgs.append(line)
    return pkgs


def _write_root_file(cijoe, path: Path, body: str, mode: str = "0644") -> None:
    """Write `body` to a root-owned path inside the rootfs via a host temp +
    sudo cp (same approach as derive_pack._write_root_file)."""
    host_tmp = Path(f"/tmp/nosi-rpi-{os.getpid()}.tmp")
    host_tmp.write_text(body)
    cijoe.run_local(f"sudo mkdir -p {path.parent}")
    cijoe.run_local(f"sudo cp {host_tmp} {path}")
    cijoe.run_local(f"sudo chmod {mode} {path}")
    host_tmp.unlink(missing_ok=True)


def target_images(cijoe) -> list[tuple[str, dict, str]]:
    """The base image + each of its derives, as (image_name, image, variant).
    Shared by rpi_image_smoketest + rpi_image_pack so each processes the full
    Pi set (headless + desktop) in one invocation without a per-variant
    --image_name."""
    images = cijoe.getconf("system-imaging.images", {})
    base_variant = cijoe.getconf("nosi", {}).get("variant")
    base_name = f"nosi-{base_variant}-arm64"
    base = images.get(base_name)
    if base is None:
        return []
    out = [(base_name, base, base_variant)]
    for entry in base.get("derive", []) or []:
        v = entry["variant"]
        name = f"nosi-{v}-arm64"
        if name in images:
            out.append((name, images[name], v))
    return out


def _resolve_path(repo_root: Path, p: str) -> Path:
    """Relative config paths resolve against the repo root; absolute paths
    (incl. expanded {{ local.env.HOME }}) pass through."""
    path = Path(p)
    return path if path.is_absolute() else (repo_root / path)


def _default_image_name(cijoe) -> str:
    nosi = cijoe.getconf("nosi", {})
    variant = nosi.get("variant", "rpios-13-headless")
    return f"nosi-{variant}-arm64"
