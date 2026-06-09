"""
Derive the shape artifacts from a baked headless rootfs
=======================================================

Layered build model: the headless base bakes once (``diskimage_build``).
The derived shapes (desktop / wsl / docker) are NOT re-baked. This step
takes a *copy* of the base qcow2, chroots in, runs
``apply.sh <derived-variant> --shape-only`` (which re-stamps identity and
installs the shape's packages + config via its shape step, skipping the
base infrastructure that already ran), optionally strips
kernel/boot/cloud-init, and repackages by output mode:

  output = "img"   bootable .img.gz   (desktop; no strip, kernel kept)
  output = "tar"   rootfs .tar.gz     (wsl; strip)
  output = "oci"   OCI image via `docker import` (docker; strip)

Driven by the base image's ``derive`` list in the cijoe config:

  [[system-imaging.images.<base-image>.derive]]
  variant = "ubuntu-2604-wsl"
  output  = "tar"
  strip   = true

When the base image has no ``derive`` list the step no-ops, so the same
``build.yaml`` drives every base (headless / freebsd) unchanged.

Mechanism (qemu-nbd + chroot): libguestfs is avoided because its
appliance networking (passt) reliably fails on hosted GitHub-Actions
runners. qemu-nbd needs only ``qemu-utils`` (already present for the
bake) and the loadable ``nbd`` module (shipped on the runners;
``sudo modprobe nbd`` locally). The chroot shares the host's
network namespace, and we bind the host's /etc/resolv.conf in, so the
shape step's apt/dnf/curl/uvx fetches resolve.

Artifact naming (also consumed by .github/workflows/build.yml):
  img : <disk_dir>/nosi-<variant>-x86_64.img.gz (+ .sha256)
  tar : <disk_dir>/nosi-<variant>.tar.gz        (+ .sha256)
  oci : local docker image tagged nosi-<variant>:latest (build.yml
        retags to ghcr.io/<repo>/<variant> and pushes)

Retargetable: False
"""

from __future__ import annotations

import errno
import logging as log
import os
import shutil
from argparse import ArgumentParser
from pathlib import Path

from imgshrink import shrink_raw


def _gzip_cmd() -> str:
    """pigz (parallel, all cores) when present, else stock gzip; same .gz
    format either way. The derive's tar/img passes are -9, so on a 4-core
    runner pigz is the difference between one busy core and four."""
    return "pigz" if shutil.which("pigz") else "gzip"


# Packages purged for stripped shapes (wsl / docker): kernel + bootloader
# + firmware are meaningless without our own kernel; cloud-init + netplan
# + NetworkManager because WSL and containers own their own first-boot +
# networking. qemu + podman/buildah/skopeo stay (nested virt + containers
# are the point of the docker shape, and useful under WSL too).
STRIP_PURGE_GLOBS = [
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
    "dkms",
]

STRIP_SCRIPT_TEMPLATE = """\
#!/bin/sh
set -u
export DEBIAN_FRONTEND=noninteractive
to_purge=""
for glob in {globs}; do
    matches=$(dpkg-query -W -f='${{Package}}\\n' "$glob" 2>/dev/null || true)
    [ -z "$matches" ] && continue
    to_purge="$to_purge $matches"
done
if [ -n "$to_purge" ]; then
    apt-get -y --allow-remove-essential purge $to_purge || true
fi
apt-get -y autoremove --purge || true
apt-get clean || true
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
rm -f /etc/ssh/ssh_host_*
"""

NBD_DEV = "/dev/nbd0"

# OCI image config for the docker shape. PATH includes /usr/local/bin so
# the uv / cargo / pipx-shim tools resolve; CMD is an interactive shell
# since GHA job-containers override the entrypoint and run steps directly.
OCI_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Override the base system-imaging image to derive from. "
        "Defaults to nosi-<variant>-x86_64 (variant from [nosi]).",
    )


def main(args, cijoe):
    image_name = args.image_name or _default_image_name(cijoe)
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    derives = image.get("derive")
    if not derives:
        log.info(
            f"Image '{image_name}' has no [[...derive]] entries; skipping "
            "(expected for a base that has no derived shapes)."
        )
        return 0

    qcow2_path = Path(image["disk"]["path"])
    if not qcow2_path.exists():
        log.error(f"Baked base qcow2 not found: {qcow2_path}")
        return errno.ENOENT
    disk_dir = qcow2_path.parent

    # nbd module + a clean nbd0 once for the whole run.
    cijoe.run_local("sudo modprobe nbd max_part=8")

    total = len(derives)
    log.info(f"{image_name}: building {total} derived shape(s) from the base")
    for idx, entry in enumerate(derives, start=1):
        title = (
            f"derive {idx}/{total}: {entry['variant']} "
            f"(output={entry['output']}, strip={bool(entry.get('strip'))})"
        )
        _group_open(cijoe, title)
        rc = _derive_one(cijoe, qcow2_path, disk_dir, entry)
        _group_close(cijoe, title, rc)
        if rc:
            return rc
    return 0


def _group_open(cijoe, title: str) -> None:
    """Announce the start of a derive. The whole build is one `make build`
    step, so without an explicit marker the start of the desktop/wsl/docker
    derives is buried in the bake's output. `::group::<title>` folds the
    derive into a named, collapsible, individually-timed section on GitHub
    Actions; elsewhere it's just a visible banner line. Emitted via
    run_local so --monitor streams it to the step's stdout, where the
    Actions log processor sees the workflow command at line start.
    """
    bar = "=" * 64
    cijoe.run_local(
        f'sh -c \'printf "::group::%s\\n%s\\n[derive] start $(date -u +%H:%M:%S)  %s\\n%s\\n" '
        f'"{title}" "{bar}" "{title}" "{bar}"\''
    )


def _group_close(cijoe, title: str, rc: int) -> None:
    """Close the derive's log group with a result + timestamp. Always runs
    (even on failure) so the `::group::` is balanced and later output isn't
    folded under it."""
    status = "OK" if rc == 0 else f"FAILED (rc={rc})"
    cijoe.run_local(
        f'sh -c \'printf "[derive] end   $(date -u +%H:%M:%S)  %s -> %s\\n::endgroup::\\n" '
        f'"{title}" "{status}"\''
    )


def _derive_one(cijoe, base_qcow2: Path, disk_dir: Path, entry: dict) -> int:
    variant = entry["variant"]
    output = entry["output"]
    strip = bool(entry.get("strip", False))
    if output not in ("img", "tar", "oci"):
        log.error(f"derive '{variant}': unknown output {output!r} (img|tar|oci)")
        return errno.EINVAL

    # The per-derive banner (_group_open) already announces variant/output/
    # strip to the log; no separate log.info needed here.
    work = disk_dir / f"nosi-{variant}.work.qcow2"
    err, _ = cijoe.run_local(f"cp -f {base_qcow2} {work}")
    if err:
        log.error("failed to copy base qcow2")
        return err

    mnt = Path(f"/mnt/nosi-derive-{variant}-{os.getpid()}")
    try:
        rc = _provision_and_package(cijoe, work, mnt, variant, output, strip, disk_dir)
    finally:
        work.unlink(missing_ok=True)
    return rc


def _provision_and_package(cijoe, work, mnt, variant, output, strip, disk_dir) -> int:
    cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")
    err, _ = cijoe.run_local(f"sudo qemu-nbd --connect={NBD_DEV} {work}")
    if err:
        log.error("qemu-nbd connect failed")
        return err

    bind_cleanup: list[str] = []
    post_cleanup = [f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true"]
    try:
        cijoe.run_local(f"sudo partprobe {NBD_DEV} >/dev/null 2>&1 || true")
        rootfs_part = _find_rootfs_partition(cijoe, work)
        if not rootfs_part:
            log.error(f"no ext4/btrfs/xfs rootfs partition found on {NBD_DEV}")
            return errno.ENODEV

        cijoe.run_local(f"sudo mkdir -p {mnt}")
        err, _ = cijoe.run_local(f"sudo mount {rootfs_part} {mnt}")
        if err:
            log.error(f"mount {rootfs_part} failed")
            return err
        post_cleanup.append(f"sudo umount -R {mnt} 2>/dev/null || true")
        post_cleanup.append(f"sudo rmdir {mnt} 2>/dev/null || true")

        # Where the rootfs actually lives (mount point, or a btrfs `root`
        # subvol underneath it). Everything below operates on `rootfs`.
        rootfs = _rootfs_dir(cijoe, mnt)
        if not rootfs:
            log.error(
                f"{rootfs_part} mounted at {mnt} but no /etc/os-release at "
                f"the top level or a `root` subvol"
            )
            return errno.ENOENT

        # Kernel API filesystems + DNS for the chroot's package installs.
        for sub in ("dev", "proc", "sys", "run"):
            err, _ = cijoe.run_local(f"sudo mount --bind /{sub} {rootfs}/{sub}")
            if err:
                log.error(f"bind-mount {sub} failed")
                return err
            bind_cleanup.append(f"sudo umount {rootfs}/{sub} 2>/dev/null || true")
        # Bind the host's resolv.conf so apt/dnf/curl/uvx resolve. Bind
        # (not copy) leaves the image's own resolv config intact underneath.
        err, _ = cijoe.run_local(f"sudo mount --bind /etc/resolv.conf {rootfs}/etc/resolv.conf")
        if err:
            log.error("bind-mount /etc/resolv.conf failed")
            return err
        bind_cleanup.append(f"sudo umount {rootfs}/etc/resolv.conf 2>/dev/null || true")

        rc = _chroot_provision(cijoe, rootfs, variant, strip)
        if rc:
            return rc

        # Export the derived variant's own metadata (98-metadata wrote it in
        # the chroot, reflecting the derived shape/variant + installed
        # inventory, and it survives the strip). build.yml reads this for
        # the derived artifact's ORAS annotations rather than the base's.
        meta_dst = disk_dir / f"nosi-{variant}.metadata.json"
        cijoe.run_local(
            f"sudo cp {rootfs}/etc/nosi-metadata.json {meta_dst} && "
            f"sudo chown $(id -u):$(id -g) {meta_dst}"
        )

        # tar/oci read the live mount; drop binds first so the rootfs view
        # is static (volatile /sys etc. trip tar's "file changed" check).
        if output in ("tar", "oci"):
            for cmd in reversed(bind_cleanup):
                cijoe.run_local(cmd)
            bind_cleanup.clear()
            return _package_rootfs(cijoe, rootfs, variant, output, disk_dir)

        # img: unmount everything + disconnect, then convert the qcow2.
        for cmd in reversed(bind_cleanup):
            cijoe.run_local(cmd)
        bind_cleanup.clear()
        for cmd in reversed(post_cleanup):
            cijoe.run_local(cmd)
        post_cleanup.clear()
        return _package_img(cijoe, work, variant, disk_dir)
    finally:
        for cmd in reversed(bind_cleanup):
            cijoe.run_local(cmd)
        for cmd in reversed(post_cleanup):
            cijoe.run_local(cmd)


def _chroot_provision(cijoe, mnt, variant, strip) -> int:
    """Refresh package metadata, run the shape step, optionally strip."""
    osr = _read_os_release_id(mnt)
    if osr in ("debian", "ubuntu"):
        refresh = "apt-get update"
        clean = "apt-get clean && rm -rf /var/lib/apt/lists/*"
    elif osr == "fedora":
        refresh = "dnf -y makecache"
        clean = "dnf clean all && rm -rf /var/cache/dnf/*"
    else:
        log.error(f"derive '{variant}': unsupported distro id {osr!r} in rootfs")
        return errno.EINVAL

    # The base bake cleared package metadata in its final cleanup, so the
    # shape step's installs need a fresh index first.
    err, _ = cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q(refresh)}")
    if err:
        log.error("chroot package-metadata refresh failed")
        return err

    apply_cmd = f"/opt/nosi/provision/apply.sh {variant} --shape-only"
    err, _ = cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q(apply_cmd)}")
    if err:
        log.error(f"chroot apply.sh {variant} --shape-only failed")
        return err

    if strip:
        script = mnt / "tmp" / "nosi-strip.sh"
        body = STRIP_SCRIPT_TEMPLATE.format(globs=" ".join(STRIP_PURGE_GLOBS))
        cijoe.run_local(f"sudo mkdir -p {mnt}/tmp")
        # Write via tee so the heredoc lands inside the (root-owned) rootfs.
        _write_root_file(cijoe, script, body, mode="0755")
        err, _ = cijoe.run_local(f"sudo chroot {mnt} /bin/sh /tmp/nosi-strip.sh")
        if err:
            log.error("chroot strip script failed")
            return err
        cijoe.run_local(f"sudo rm -f {script}")

    cijoe.run_local(f"sudo chroot {mnt} /bin/sh -c {_q(clean)}")
    return 0


def _package_rootfs(cijoe, mnt, variant, output, disk_dir) -> int:
    """Tar the mounted rootfs; gzip it (wsl) or docker-import it (docker)."""
    if output == "tar":
        tar_path = disk_dir / f"nosi-{variant}.tar"
        gz_path = disk_dir / f"nosi-{variant}.tar.gz"
        err, _ = cijoe.run_local(
            f"sudo tar --xattrs --acls --numeric-owner "
            f"--exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' "
            f"--exclude='./run/*' --exclude='./tmp/*' --exclude='./lost+found' "
            f"-cf {tar_path} -C {mnt} ."
        )
        if err:
            log.error("tar of rootfs failed")
            return err
        cijoe.run_local(f"sudo chown $(id -u):$(id -g) {tar_path}")
        err, _ = cijoe.run_local(f"{_gzip_cmd()} -9 -c {tar_path} > {gz_path}")
        if err:
            return err
        cijoe.run_local(f"sha256sum {gz_path} > {gz_path}.sha256")
        tar_path.unlink(missing_ok=True)
        log.info(f"derive '{variant}': wrote {gz_path}")
        return 0

    # output == "oci": stream the rootfs tar straight into docker import.
    tag = f"nosi-{variant}:latest"
    changes = (
        f"--change 'ENV PATH={OCI_PATH}' "
        f"--change 'WORKDIR /root' "
        f"--change 'CMD [\"/bin/bash\"]' "
        f"--change 'LABEL org.opencontainers.image.title=nosi-{variant}'"
    )
    err, _ = cijoe.run_local(
        f"sudo tar --xattrs --acls --numeric-owner "
        f"--exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' "
        f"--exclude='./run/*' --exclude='./tmp/*' --exclude='./lost+found' "
        f"-cf - -C {mnt} . | docker import {changes} - {tag}"
    )
    if err:
        log.error("docker import of rootfs failed")
        return err

    # Container smoketest: the OCI image must actually run and carry the
    # bootstrap tooling (cijoe + qemu). Gates publish the same way the
    # qcow2 smoketest does -- a broken container fails the build rather
    # than shipping a bootstrap image that can't launch a guest.
    smoke = "cijoe --version && qemu-system-x86_64 --version"
    err, _ = cijoe.run_local(f"docker run --rm {tag} /bin/bash -lc {_q(smoke)}")
    if err:
        log.error(f"container smoketest failed for {tag} (cijoe/qemu missing?)")
        return err
    log.info(f"derive '{variant}': imported + smoketested OCI image {tag}")
    return 0


def _package_img(cijoe, work, variant, disk_dir) -> int:
    """Convert the modified qcow2 to a gzip-compressed raw .img.gz."""
    raw_path = disk_dir / f"nosi-{variant}-x86_64.img"
    gz_path = disk_dir / f"nosi-{variant}-x86_64.img.gz"
    err, _ = cijoe.run_local(f"qemu-img convert -O raw {work} {raw_path}")
    if err:
        log.error("qemu-img convert qcow2 -> raw failed")
        return err
    # Shrink the derived raw to fit before compressing, same as the base
    # img_gz_pack does. ext4 (Debian desktop) shrinks; Fedora's btrfs desktop is
    # left full-size. nosi-growroot expands it back on first boot.
    rc = shrink_raw(cijoe, raw_path)
    if rc:
        log.error(f"derive '{variant}': raw shrink produced an invalid table")
        raw_path.unlink(missing_ok=True)
        return rc
    err, _ = cijoe.run_local(f"{_gzip_cmd()} -9 -c {raw_path} > {gz_path}")
    if err:
        return err
    cijoe.run_local(f"sha256sum {gz_path} > {gz_path}.sha256")
    raw_path.unlink(missing_ok=True)
    log.info(f"derive '{variant}': wrote {gz_path}")
    return 0


def _find_rootfs_partition(cijoe, work, attempts=10):
    """Largest ext4 / btrfs / xfs partition on NBD_DEV -- the rootfs
    (/boot, ESP, BIOS-boot are smaller or other fstypes). Cloud images
    differ by distro: Ubuntu / Debian ship ext4, Fedora ships btrfs,
    others ship xfs; pick the largest rootfs-capable filesystem."""
    import json

    rootfs_fstypes = ("ext4", "btrfs", "xfs")
    out_file = work.with_suffix(".lsblk.json")
    try:
        for _ in range(attempts):
            err, _ = cijoe.run_local(
                f"sudo lsblk -J -b -o NAME,FSTYPE,SIZE,TYPE {NBD_DEV} > {out_file}"
            )
            if err == 0 and out_file.exists():
                try:
                    data = json.loads(out_file.read_text())
                except (json.JSONDecodeError, OSError):
                    data = {}
                candidates = []
                for dev in data.get("blockdevices", []):
                    for part in dev.get("children") or []:
                        if part.get("type") == "part" and part.get("fstype") in rootfs_fstypes:
                            size = part.get("size")
                            if size is not None:
                                candidates.append((int(size), part["name"]))
                if candidates:
                    candidates.sort(reverse=True)
                    return f"/dev/{candidates[0][1]}"
            cijoe.run_local("sleep 1")
        return None
    finally:
        out_file.unlink(missing_ok=True)


def _rootfs_dir(cijoe, mnt: Path) -> Path | None:
    """The directory holding the rootfs under a freshly-mounted partition.

    ext4 / xfs (and a btrfs image whose default subvolume is the root)
    put /etc/os-release right at the mount point. A btrfs image mounted
    at its top-level subvolume (subvolid 5) instead keeps the rootfs in
    the `root` subvolume (Fedora's layout), so it lives at <mnt>/root.
    Returns whichever has /etc/os-release, or None. `sudo test` because
    the mounted tree is root-owned.
    """
    for cand in (mnt, mnt / "root"):
        err, _ = cijoe.run_local(f"sudo test -e {cand}/etc/os-release")
        if err == 0:
            return cand
    return None


def _read_os_release_id(mnt: Path) -> str | None:
    try:
        for raw in (mnt / "etc" / "os-release").read_text().splitlines():
            if raw.startswith("ID="):
                return raw.partition("=")[2].strip().strip('"').strip("'")
    except OSError:
        pass
    return None


def _write_root_file(cijoe, path: Path, body: str, mode: str = "0644"):
    """Write `body` to a root-owned path inside the rootfs via tee."""
    host_tmp = Path(f"/tmp/nosi-derive-{os.getpid()}.tmp")
    host_tmp.write_text(body)
    cijoe.run_local(f"sudo cp {host_tmp} {path}")
    cijoe.run_local(f"sudo chmod {mode} {path}")
    host_tmp.unlink(missing_ok=True)


def _q(s: str) -> str:
    """Single-quote a string for `sh -c`."""
    return "'" + s.replace("'", "'\\''") + "'"


def _default_image_name(cijoe) -> str:
    nosi = cijoe.getconf("nosi", {})
    variant = nosi.get("variant", "ubuntu-2604-headless")
    return f"nosi-{variant}-x86_64"
