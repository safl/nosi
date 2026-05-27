"""
Publish a baked nosi qcow2 as a dd-able .img.gz
==============================================

Converts the qcow2 produced by ``diskimage_build`` to raw, gzip-compresses
the result, and writes a sha256sum alongside.

Why gzip rather than zstd: nosi base images are flashed once during operator
setup, not on a per-job hot path. Gzip's universal flasher / OS / tooling
support wins over zstd's marginal speed advantage on a one-shot setup; bty
itself made the same call for the images it ships. bty's flash code accepts
any of .img.{zst,xz,gz,bz2}, so consumers can still pick a different
compressor if they need to.

Reads the ``publish`` section of ``system-imaging.images.<image_name>``:

  publish.raw_path    intermediate raw image path
  publish.gz_path     final .img.gz path
  publish.gzip_level  compression level (1..9; 9 default)

Adapted from github.com/safl/bty's cijoe/scripts/img_gz_publish.py.

Retargetable: False
"""

from __future__ import annotations

import errno
import logging as log
from argparse import ArgumentParser
from pathlib import Path


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

    disk = image.get("disk", {})
    publish = image.get("publish", {})
    if not publish:
        log.error(f"Image '{image_name}' has no [publish] section")
        return errno.EINVAL

    qcow2_path = Path(disk["path"])
    raw_path = Path(publish["raw_path"])
    gz_path = Path(publish["gz_path"])
    level = int(publish.get("gzip_level", 9))

    if not qcow2_path.exists():
        log.error(f"Baked qcow2 not found: {qcow2_path}")
        return errno.ENOENT

    raw_path.parent.mkdir(parents=True, exist_ok=True)
    gz_path.parent.mkdir(parents=True, exist_ok=True)

    log.info(f"Converting {qcow2_path} -> {raw_path} (raw)")
    err, _ = cijoe.run_local(f"qemu-img convert -O raw {qcow2_path} {raw_path}")
    if err:
        log.error("Failed converting qcow2 to raw")
        return err

    log.info(f"Compressing {raw_path} -> {gz_path} (gzip -{level})")
    err, _ = cijoe.run_local(f"gzip -{level} -c {raw_path} > {gz_path}")
    if err:
        log.error("Failed gzip-compressing raw image")
        return err

    err, _ = cijoe.run_local(f"sha256sum {gz_path} > {gz_path}.sha256")
    if err:
        log.error("Failed computing sha256sum")
        return err

    # The raw .img is an 8-12 GiB intermediate; once the .img.gz + .sha256
    # are written it has no further consumer (artifact upload + GHCR push
    # take only the .gz). Drop it to free disk on hosted CI runners.
    raw_path.unlink(missing_ok=True)

    return 0


def _default_image_name(cijoe) -> str:
    nosi = cijoe.getconf("nosi", {})
    variant = nosi.get("variant", "debian-13-sysdev")
    return f"nosi-{variant}-x86_64"
