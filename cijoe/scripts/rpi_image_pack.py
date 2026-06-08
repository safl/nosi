"""
Pack baked nosi Raspberry Pi (arm64) images as dd-able .img.gz
==============================================================

``img_gz_pack`` converts a qcow2 to raw then gzips it. The Pi build
(``rpi_image_build``) already emits a raw ``.img`` at each image's
``disk.path``, so this thin packer just gzips it (+ a sha256 sidecar) -- no
qemu-img convert.

Iterates the base image + all its derives (the full Pi set: headless +
desktop) in one invocation, so the CI step needs no per-variant argument.
Reads ``publish.gz_path`` / ``publish.gzip_level`` from each image's config.

Runs AFTER ``rpi_image_smoketest``, so only smoketest-passed images are packed.

Retargetable: False
"""

from __future__ import annotations

import errno
import logging as log
import shutil
from argparse import ArgumentParser
from pathlib import Path

from rpi_image_build import _resolve_path, target_images


def _gzip_cmd() -> str:
    """pigz (all cores) when present, else stock gzip; same .gz format."""
    return "pigz" if shutil.which("pigz") else "gzip"


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Pack only this image. Defaults to the base + all its derives.",
    )


def main(args, cijoe):
    images = cijoe.getconf("system-imaging.images", {})
    if args.image_name:
        image = images.get(args.image_name)
        if not image:
            log.error(f"Image '{args.image_name}' not found in config")
            return errno.EINVAL
        targets = [(args.image_name, image, args.image_name)]
    else:
        targets = target_images(cijoe)
    if not targets:
        log.error("no Pi images resolved from config")
        return errno.EINVAL

    repo_root = Path.cwd().parent
    for image_name, image, _ in targets:
        rc = _pack_one(cijoe, repo_root, image_name, image)
        if rc:
            return rc
    return 0


def _pack_one(cijoe, repo_root: Path, image_name: str, image: dict) -> int:
    publish = image.get("publish", {})
    if not publish.get("gz_path"):
        log.error(f"{image_name}: no publish.gz_path in config")
        return errno.EINVAL

    src = _resolve_path(repo_root, image["disk"]["path"])
    gz_path = _resolve_path(repo_root, publish["gz_path"])
    level = int(publish.get("gzip_level", 9))

    if not src.exists():
        log.error(f"{image_name}: baked image not found: {src}")
        return errno.ENOENT

    gz_path.parent.mkdir(parents=True, exist_ok=True)
    gz = _gzip_cmd()
    log.info(f"Compressing {src} -> {gz_path} ({gz} -{level})")
    err, _ = cijoe.run_local(f"{gz} -v -{level} -c {src} > {gz_path}")
    if err:
        log.error(f"{image_name}: gzip failed")
        return err
    err, _ = cijoe.run_local(f"sha256sum {gz_path} > {gz_path}.sha256")
    if err:
        log.error(f"{image_name}: sha256sum failed")
        return err
    return 0
