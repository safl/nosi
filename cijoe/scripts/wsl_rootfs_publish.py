"""
Publish a baked nosi qcow2 as a WSL2 rootfs .tar.gz
===================================================

For the aidev flavor we want a single bake to feed two derived artifacts:
the flashable .img.gz produced by ``img_gz_publish``, and a WSL2 rootfs
tarball consumable by ``wsl --import``. This script handles the latter.

Pipeline (qemu-nbd + chroot; no libguestfs):

  1. Copy the baked qcow2 to a per-build scratch file (we do not mutate
     the .img.gz source-of-truth).
  2. ``modprobe nbd`` and ``qemu-nbd --connect`` the scratch qcow2 onto
     a host NBD block device.
  3. Mount the rootfs partition, bind-mount /dev /proc /sys /run from
     the host, and ``chroot`` in to run a strip script that apt-purges
     the kernel, bootloader, firmware, cloud-init, netplan, and
     NetworkManager. qemu + podman/buildah + the rest of the user space
     stay (WSL2 exposes /dev/kvm via nested virt, and containers are a
     primary use case). Vendor GPU/NIC drivers aren't installed in
     aidev today; when they are, they'll need to be added to the strip
     list since WSL gets GPU access via the Windows-side driver rather
     than an in-rootfs kernel module.
  4. ``tar`` the stripped rootfs into a .tar (xattrs + acls preserved,
     bind-mount dirs excluded).
  5. Unmount, disconnect nbd, gzip + sha256, drop the .tar + scratch.

We use qemu-nbd rather than libguestfs because libguestfs's appliance
networking (passt) reliably fails on hosted GitHub-Actions runners --
``passt exited with status 1`` before any of our scripts run. qemu-nbd
needs only ``qemu-utils`` (already installed for the bake) and the
loadable ``nbd`` kernel module (shipped on Ubuntu hosted runners).

Reads the ``publish_wsl`` section of
``system-imaging.images.<image_name>``:

  publish_wsl.work_qcow2_path   scratch copy of the baked qcow2
  publish_wsl.tar_path          intermediate uncompressed tarball
  publish_wsl.gz_path           final .tar.gz path
  publish_wsl.gzip_level        compression level (1..9; 9 default)

When ``publish_wsl`` is absent (headless variants), the step no-ops with a
success return so the same cijoe task file can drive every variant.

Retargetable: False
"""

from __future__ import annotations

import errno
import json
import logging as log
import os
from argparse import ArgumentParser
from pathlib import Path


# Packages purged from the WSL rootfs. Each glob is what apt would expand;
# we feed them through dpkg-query first so missing globs are silent. The
# set covers two buckets:
#
#   * kernel + bootloader + firmware  -- meaningless under WSL's host kernel
#   * cloud-init + netplan + NM       -- WSL handles its own first-boot and
#                                        networking from the Windows side
#
# Notable things deliberately NOT purged: qemu + ovmf (WSL2 exposes
# /dev/kvm with nested virtualization, so the qemu workflow is alive),
# podman + buildah + skopeo (containers under WSL2 are a primary use
# case). The r8125 source tree we register with DKMS at bake time for
# bare-metal RTL8125 NICs is purged via the dkms package + the
# /usr/src/r8125-* glob in the strip script (no kernel under WSL).
# Vendor GPU stacks aren't baked into aidev today; if one ever is, add
# its kernel-tied packages here.
WSL_PURGE_GLOBS = [
    "linux-image-*",
    "linux-headers-*",
    "linux-modules-*",
    "linux-modules-extra-*",
    "linux-generic*",
    "grub-*",
    "shim-signed",
    "shim-helpers-*",
    "efibootmgr",
    "firmware-*",
    "linux-firmware",
    "cloud-init",
    "cloud-guest-utils",
    "cloud-initramfs-copymods",
    "cloud-initramfs-dyn-netconf",
    "netplan.io",
    "network-manager",
    # DKMS framework + any source trees we registered at bake time
    # (currently just r8125 for bare-metal RTL8125 NICs). Useless under
    # WSL where the kernel is host-provided; module builds at next kernel
    # update would also fail noisily without headers.
    "dkms",
]


# Strip script run inside the chroot. apt commands tolerate non-zero
# exits (postrm hooks for kernel packages call update-initramfs /
# update-grub which can fail harmlessly inside a chroot that we're
# about to discard anyway) -- the apt state changes we care about
# happen before the postrm calls.
STRIP_SCRIPT_TEMPLATE = """\
#!/bin/sh
set -u
export DEBIAN_FRONTEND=noninteractive

# Expand the purge globs against installed dpkg state so non-matching
# globs are silent (e.g. mlnx-ofed-kernel-* on a bake that never
# installed MLNX_OFED would otherwise fail apt's argument check).
to_purge=""
for glob in {globs}; do
    matches=$(dpkg-query -W -f='${{Package}}\\n' "$glob" 2>/dev/null || true)
    [ -z "$matches" ] && continue
    to_purge="$to_purge $matches"
done
if [ -n "$to_purge" ]; then
    # --allow-remove-essential: shim-signed and grub-efi-amd64-signed
    # are flagged Essential on Ubuntu cloud images; without this flag
    # apt aborts the whole purge ("Essential packages were removed and
    # -y was used without --allow-remove-essential"), leaving the
    # entire kernel/firmware/grub tree on disk.
    apt-get -y --allow-remove-essential purge $to_purge || true
fi
apt-get -y autoremove --purge || true
apt-get clean || true

# Scrub state that references the now-gone kernel/bootloader/init
# plumbing. /boot is wiped wholesale (no kernel under WSL); /lib/modules
# and /lib/firmware likewise. cloud-init's state directories get a hard
# rm in case the apt purge raced their postrm.
rm -rf \\
    /boot/* \\
    /var/cache/apt/archives/* \\
    /var/lib/apt/lists/* \\
    /etc/netplan/* \\
    /var/lib/cloud \\
    /etc/cloud \\
    /lib/modules/* \\
    /usr/lib/modules/* \\
    /lib/firmware \\
    /usr/lib/firmware \\
    /etc/grub.d \\
    /etc/default/grub \\
    /var/log/installer \\
    /var/lib/dkms \\
    /usr/src/r8125-*

# Drop SSH host keys (regenerated on first WSL boot if sshd is started).
rm -f /etc/ssh/ssh_host_*
"""


# Block device that qemu-nbd will use. /dev/nbd0 is the conventional
# default; the script disconnects any stale binding before reusing it.
NBD_DEV = "/dev/nbd0"


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Override the system-imaging image to publish. Defaults to "
        "nosi-<variant>-x86_64 (variant from [nosi] in the cijoe config).",
    )


def main(args, cijoe):
    image_name = args.image_name or _default_image_name(cijoe)
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    publish_wsl = image.get("publish_wsl")
    if not publish_wsl:
        log.info(
            f"Image '{image_name}' has no [publish_wsl] section; "
            "skipping WSL rootfs publish (expected for non-aidev variants)."
        )
        return 0

    disk = image.get("disk", {})
    qcow2_path = Path(disk["path"])
    work_path = Path(publish_wsl["work_qcow2_path"])
    tar_path = Path(publish_wsl["tar_path"])
    gz_path = Path(publish_wsl["gz_path"])
    level = int(publish_wsl.get("gzip_level", 9))

    if not qcow2_path.exists():
        log.error(f"Baked qcow2 not found: {qcow2_path}")
        return errno.ENOENT

    for p in (work_path, tar_path, gz_path):
        p.parent.mkdir(parents=True, exist_ok=True)

    log.info(f"Copying {qcow2_path} -> {work_path} (WSL strip workspace)")
    err, _ = cijoe.run_local(f"cp -f {qcow2_path} {work_path}")
    if err:
        log.error("Failed to copy baked qcow2")
        return err

    strip_script_host = work_path.with_suffix(".strip.sh")
    strip_script_host.write_text(
        STRIP_SCRIPT_TEMPLATE.format(globs=" ".join(WSL_PURGE_GLOBS))
    )
    strip_script_host.chmod(0o755)

    mnt = Path(f"/mnt/nosi-wsl-{os.getpid()}")
    err = _strip_and_tar(cijoe, work_path, strip_script_host, mnt, tar_path)
    strip_script_host.unlink(missing_ok=True)
    if err:
        return err

    log.info(f"Compressing {tar_path} -> {gz_path} (gzip -{level})")
    err, _ = cijoe.run_local(f"gzip -{level} -c {tar_path} > {gz_path}")
    if err:
        log.error("Failed gzip-compressing rootfs tarball")
        return err

    err, _ = cijoe.run_local(f"sha256sum {gz_path} > {gz_path}.sha256")
    if err:
        log.error("Failed computing sha256sum")
        return err

    # Drop large intermediates: the .tar (uncompressed, ~3-6 GiB) and
    # the scratch qcow2. Only the .tar.gz + .sha256 have downstream
    # consumers.
    tar_path.unlink(missing_ok=True)
    work_path.unlink(missing_ok=True)

    return 0


def _strip_and_tar(cijoe, work_path, strip_script_host, mnt, tar_path):
    """Attach the qcow2 to nbd, chroot-strip, tar the rootfs out.

    Cleanup runs in two layers: bind mounts are dropped before tar
    runs (otherwise the host's volatile /sys etc. trip tar's
    "file changed as we read it" check even with --exclude), the
    rootfs mount + nbd-disconnect happen in finally. Returns 0 on
    success, non-zero on failure.
    """
    # nbd module is loadable on Ubuntu hosted runners but typically not
    # auto-loaded. max_part=8 enables in-kernel partition scan so
    # /dev/nbd0p1 et al. show up after connect.
    cijoe.run_local("sudo modprobe nbd max_part=8")
    # Clear any stale prior binding -- harmless when nbd0 is free.
    cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")

    log.info(f"Attaching {work_path} to {NBD_DEV} via qemu-nbd")
    err, _ = cijoe.run_local(f"sudo qemu-nbd --connect={NBD_DEV} {work_path}")
    if err:
        log.error("qemu-nbd connect failed")
        return err

    # Two cleanup buckets: bind-mount unmounts that happen *before* tar
    # (so the rootfs view is static while we read it), and the rest
    # (rootfs umount + nbd disconnect) that happen in finally.
    bind_cleanup = []
    post_cleanup = [
        f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true",
    ]

    try:
        # Force partition rescan, then probe lsblk until partitions appear
        # and pick the rootfs (largest ext4). Ubuntu cloud images today
        # land it on p1 with p14/p15 as BIOS-boot + ESP tail partitions,
        # but layouts shift across releases and other distros use other
        # numbering -- detection rather than a hardcode keeps the script
        # honest as the matrix grows.
        cijoe.run_local(f"sudo partprobe {NBD_DEV} >/dev/null 2>&1 || true")
        rootfs_part = _find_rootfs_partition(cijoe, work_path, NBD_DEV)
        if not rootfs_part:
            log.error(
                f"No ext4 partition found on {NBD_DEV}; "
                "cannot identify the rootfs to mount."
            )
            return errno.ENODEV

        cijoe.run_local(f"sudo mkdir -p {mnt}")
        log.info(f"Mounting {rootfs_part} at {mnt}")
        err, _ = cijoe.run_local(f"sudo mount {rootfs_part} {mnt}")
        if err:
            log.error(f"mount {rootfs_part} failed")
            return err
        post_cleanup.append(f"sudo rmdir {mnt} 2>/dev/null || true")
        post_cleanup.append(f"sudo umount {mnt} 2>/dev/null || true")

        # Bind-mount the kernel API filesystems so the chroot's apt /
        # dpkg postrm scripts can find /dev/null, /proc/self, /sys etc.
        binds = ("dev", "proc", "sys", "run")
        for sub in binds:
            err, _ = cijoe.run_local(
                f"sudo mount --bind /{sub} {mnt}/{sub}"
            )
            if err:
                log.error(f"bind-mount {sub} failed")
                return err
            bind_cleanup.append(f"sudo umount {mnt}/{sub} 2>/dev/null || true")

        # Copy strip script in and run via chroot.
        strip_in_guest = f"{mnt}/tmp/nosi-strip.sh"
        err, _ = cijoe.run_local(
            f"sudo cp {strip_script_host} {strip_in_guest}"
        )
        if err:
            return err
        cijoe.run_local(f"sudo chmod 0755 {strip_in_guest}")

        log.info("Stripping HW + boot plumbing via chroot")
        err, _ = cijoe.run_local(f"sudo chroot {mnt} /tmp/nosi-strip.sh")
        if err:
            log.error("chroot strip script failed")
            return err

        cijoe.run_local(f"sudo rm -f {strip_in_guest}")

        # Drop bind mounts *before* tar so the rootfs view is static --
        # the host's /sys et al. are too volatile to read concurrently
        # ("tar: ./sys: file changed as we read it" -> nonzero exit
        # even with the right --exclude). The mount points stay as
        # empty dirs in the rootfs, which is what WSL needs (it mounts
        # its own runtime fs's there on boot).
        for cmd in reversed(bind_cleanup):
            cijoe.run_local(cmd)
        bind_cleanup.clear()

        # Tar out the stripped rootfs. --numeric-owner avoids embedding
        # the host's /etc/passwd into the archive. The exclude list is
        # defense-in-depth (the bind mounts are already gone, so the
        # mount-point dirs are empty) plus ./tmp/* and lost+found.
        log.info(f"Tar-ing stripped rootfs to {tar_path}")
        err, _ = cijoe.run_local(
            f"sudo tar --xattrs --acls --numeric-owner "
            f"--exclude='./proc/*' --exclude='./sys/*' "
            f"--exclude='./dev/*' --exclude='./run/*' "
            f"--exclude='./tmp/*' --exclude='./lost+found' "
            f"-cf {tar_path} -C {mnt} ."
        )
        if err:
            log.error("tar of stripped rootfs failed")
            return err

        # Hand the tar back to the runner user so the subsequent
        # gzip/sha256/chown chain runs unprivileged.
        cijoe.run_local(
            f"sudo chown $(id -u):$(id -g) {tar_path}"
        )

        return 0
    finally:
        # If we bailed before unmounting the binds, do it here.
        for cmd in reversed(bind_cleanup):
            cijoe.run_local(cmd)
        for cmd in reversed(post_cleanup):
            cijoe.run_local(cmd)


def _find_rootfs_partition(cijoe, work_path, nbd_dev, attempts=10):
    """Locate the rootfs partition on `nbd_dev`.

    Strategy: ask `sudo lsblk` for its JSON view of the device (sudo so
    libblkid can read the partition superblock to populate `fstype` --
    /dev/nbd0p* default to root:disk 0660 and the runner user isn't in
    `disk`). Explicitly request `NAME,FSTYPE,SIZE,TYPE` -- the default
    `lsblk -J` column set omits `fstype` and our filter then rejects
    everything. Filter for ext4 partitions and pick the largest:
    Ubuntu 26.04 cloud images now have *two* ext4 partitions, the
    rootfs (p1, label `cloudimg-rootfs`, ~12 GiB) and a separate
    /boot (p13, label `BOOT`, ~1 GiB); the size heuristic picks the
    rootfs unambiguously. BIOS-boot is unformatted, ESP is vfat, so
    neither competes. If/when a btrfs/xfs cloud-image variant lands
    in scope, expand the accepted fstype set.

    Polls up to `attempts` times with 1s sleeps to ride out the udev
    settle window after qemu-nbd attach. On final failure logs the raw
    lsblk view so the next run can diagnose without redeploying.

    Returns the partition path (e.g. /dev/nbd0p1) or None if no
    candidate appears within the timeout.
    """
    out_file = work_path.with_suffix(".lsblk.json")
    last_data = None
    try:
        for _ in range(attempts):
            err, _ = cijoe.run_local(
                f"sudo lsblk -J -b -o NAME,FSTYPE,SIZE,TYPE {nbd_dev} > {out_file}"
            )
            if err == 0 and out_file.exists():
                try:
                    data = json.loads(out_file.read_text())
                    last_data = data
                except json.JSONDecodeError:
                    data = {}
                candidates = []
                for dev in data.get("blockdevices", []):
                    for part in dev.get("children") or []:
                        if part.get("type") != "part":
                            continue
                        if part.get("fstype") != "ext4":
                            continue
                        size = part.get("size")
                        if size is None:
                            continue
                        candidates.append((int(size), part["name"]))
                if candidates:
                    candidates.sort(reverse=True)
                    return f"/dev/{candidates[0][1]}"
            cijoe.run_local("sleep 1")
        # Detection failed -- dump what lsblk actually sees so the next
        # bake's log tells us the layout/fstype-set we need to handle.
        log.error(
            "Last `sudo lsblk -J -b` view of %s: %s",
            nbd_dev,
            json.dumps(last_data) if last_data is not None else "(no output)",
        )
        cijoe.run_local(f"sudo lsblk -O -b {nbd_dev} || true")
        return None
    finally:
        out_file.unlink(missing_ok=True)


def _default_image_name(cijoe) -> str:
    nosi = cijoe.getconf("nosi", {})
    variant = nosi.get("variant", "ubuntu-2604-aidev")
    return f"nosi-{variant}-x86_64"
