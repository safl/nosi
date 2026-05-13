"""
Publish a baked nosi qcow2 as a WSL2 rootfs .tar.gz
===================================================

For the aidev flavor we want a single bake to feed two derived artifacts:
the flashable .img.gz produced by ``img_gz_publish``, and a WSL2 rootfs
tarball consumable by ``wsl --import``. This script handles the latter.

Pipeline:

  1. Copy the baked qcow2 to a per-build scratch file (we do not mutate
     the .img.gz source-of-truth).
  2. ``virt-customize`` (libguestfs) into the scratch: apt-purge the
     kernel, bootloader, firmware, cloud-init, netplan, and
     NetworkManager. qemu + podman/buildah + the rest of the userspace
     stay (WSL2 exposes /dev/kvm via nested virt, and containers are a
     primary use case). Vendor GPU/NIC drivers aren't installed in
     aidev today; when they are, they'll need to be added to the strip
     list since WSL gets GPU access via the Windows-side driver rather
     than an in-rootfs kernel module.
  3. ``virt-tar-out`` the stripped rootfs to .tar.
  4. gzip -<level> + sha256sum sidecar; drop the .tar + scratch qcow2.

Reads the ``publish_wsl`` section of
``system-imaging.images.<image_name>``:

  publish_wsl.work_qcow2_path   scratch copy of the baked qcow2
  publish_wsl.tar_path          intermediate uncompressed tarball
  publish_wsl.gz_path           final .tar.gz path
  publish_wsl.gzip_level        compression level (1..9; 9 default)

When ``publish_wsl`` is absent (sysdev variants), the step no-ops with a
success return so the same cijoe task file can drive every variant.

Retargetable: False
"""

from __future__ import annotations

import errno
import logging as log
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
# case), and any vendor GPU/NIC kernel modules (aidev stays neutral; if
# a vendor stack ever gets baked in, add the kernel-tied packages here).
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
]


# Strip script run inside the libguestfs appliance via virt-customize --run.
# Written to a host-side tmp file rather than shipped as --run-command
# strings to keep shell quoting simple and the intent readable.
STRIP_SCRIPT_TEMPLATE = """\
#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive

# Pkgs deliberately allowed-to-fail individually: if a glob matches nothing
# (e.g. mlnx-ofed-kernel-* on a bake that never installed MLNX_OFED) apt
# returns non-zero. Run as a single shell-glob call against dpkg state
# instead so missing globs are silent.
to_purge=""
for glob in {globs}; do
    matches=$(dpkg-query -W -f='${{Package}}\\n' "$glob" 2>/dev/null || true)
    [ -z "$matches" ] && continue
    to_purge="$to_purge $matches"
done
if [ -n "$to_purge" ]; then
    apt-get -y purge $to_purge
fi
apt-get -y autoremove --purge
apt-get clean

# Scrub state that references the now-gone kernel/bootloader/init plumbing.
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
    /var/log/installer

# Old initrds left behind by linux-image's postrm if the apt run was
# truncated; harmless but bloats the tarball.
rm -f /boot/initrd.img* /boot/vmlinuz* /boot/config-* /boot/System.map-*

# Drop SSH host keys (regenerated on first WSL boot if sshd is started).
rm -f /etc/ssh/ssh_host_*
"""


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

    strip_script_path = work_path.with_suffix(".strip.sh")
    strip_script_path.write_text(
        STRIP_SCRIPT_TEMPLATE.format(globs=" ".join(WSL_PURGE_GLOBS))
    )

    log.info("Stripping HW + boot plumbing via virt-customize")
    err, _ = cijoe.run_local(
        f"virt-customize -a {work_path} --run {strip_script_path}"
    )
    if err:
        log.error("virt-customize strip failed")
        return err

    log.info(f"Extracting rootfs to {tar_path} via virt-tar-out")
    # virt-tar-out streams the contents of / from the guest into a tar
    # archive on the host. Excludes are handled inside the script above
    # (we cleaned /boot, /lib/modules, etc.); virt-tar-out itself doesn't
    # accept --exclude.
    err, _ = cijoe.run_local(f"virt-tar-out -a {work_path} / {tar_path}")
    if err:
        log.error("virt-tar-out failed")
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

    # Drop large intermediates: the .tar (uncompressed, ~3-6 GiB), the
    # scratch qcow2, and the strip script. Only the .tar.gz + .sha256 have
    # downstream consumers.
    tar_path.unlink(missing_ok=True)
    work_path.unlink(missing_ok=True)
    strip_script_path.unlink(missing_ok=True)

    return 0


def _default_image_name(cijoe) -> str:
    nosi = cijoe.getconf("nosi", {})
    variant = nosi.get("variant", "ubuntu-aidev")
    return f"nosi-{variant}-x86_64"
