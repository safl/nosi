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

  output = "img"   bootable .img.gz   (desktop / proxmox; no strip, kernel kept)
  output = "tar"   rootfs .tar.gz     (wsl; strip)
  output = "oci"   OCI image via `docker import` (docker; strip)
  output = "lxc"   rootfs .tar.zst    (Proxmox CT / Incus; strip + nspawn check)

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
  lxc : <disk_dir>/nosi-<variant>.tar.zst       (+ .sha256)

Retargetable: False
"""

from __future__ import annotations

import errno
import json
import logging as log
import os
from argparse import ArgumentParser
from pathlib import Path

from buildlib import default_image_name as _default_image_name
from buildlib import gzip_cmd as _gzip_cmd
from buildlib import q as _q
from imgshrink import shrink_raw

# Packages purged for stripped shapes (wsl / docker / lxc): kernel + bootloader
# + firmware are meaningless without our own kernel; cloud-init + netplan
# + NetworkManager because WSL and containers own their own first-boot +
# networking. qemu + podman/buildah/skopeo stay (nested virt + containers
# are the point of the docker shape, and useful under WSL too).
#
# Both strip scripts also remove tailscale (a static /usr/local install from
# step 20, invisible to dpkg/dnf so no purge glob can catch it): a VPN daemon
# belongs to the host, not to a container rootfs or a WSL distro. The
# wireguard-tools package stays -- tiny, and `wg` works inside a CT against
# the host's module.
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
    /usr/src/r8125-* \\
    /usr/local/bin/tailscale \\
    /usr/local/sbin/tailscaled \\
    /etc/systemd/system/tailscaled.service \\
    /etc/default/tailscaled \\
    /var/lib/tailscale
rm -f /etc/ssh/ssh_host_*
"""

# Fedora/dnf equivalent of STRIP_SCRIPT_TEMPLATE. dnf removes the kernel +
# firmware + bootloader + NetworkManager + cloud-init where it can (best
# effort; `|| true` so a protected/awkward package never aborts the strip),
# and the rm sweep guarantees the big trees go regardless. Same rationale as
# the apt strip: a container shares the host kernel and the platform owns
# networking + first boot.
STRIP_SCRIPT_DNF = """\
#!/bin/sh
set -u
dnf -y remove \\
    kernel kernel-core kernel-modules kernel-modules-core \\
    linux-firmware \\
    'grub2*' 'shim*' \\
    NetworkManager 'NetworkManager-*' \\
    cloud-init \\
    >/dev/null 2>&1 || true
dnf -y autoremove >/dev/null 2>&1 || true
dnf clean all >/dev/null 2>&1 || true
rm -rf \\
    /boot/* \\
    /var/cache/dnf/* \\
    /lib/modules/* \\
    /usr/lib/modules/* \\
    /lib/firmware \\
    /usr/lib/firmware \\
    /etc/grub.d \\
    /etc/default/grub \\
    /var/lib/cloud \\
    /etc/cloud \\
    /var/log/anaconda \\
    /usr/local/bin/tailscale \\
    /usr/local/sbin/tailscaled \\
    /etc/systemd/system/tailscaled.service \\
    /etc/default/tailscaled \\
    /var/lib/tailscale
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
    if output not in ("img", "tar", "oci", "lxc"):
        log.error(f"derive '{variant}': unknown output {output!r} (img|tar|oci|lxc)")
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
        # dev/pts separately: a plain bind of /dev does not carry submounts,
        # and without a pty apt logs "E: Can not write log (Is /dev/pts
        # mounted?)" on every chroot transaction (cleanup runs reversed, so
        # pts unmounts before dev).
        for sub in ("dev", "dev/pts", "proc", "sys", "run"):
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
        err, _ = cijoe.run_local(
            f"sudo cp {rootfs}/etc/nosi-metadata.json {meta_dst} && "
            f"sudo chown $(id -u):$(id -g) {meta_dst}"
        )
        if err:
            # build.yml reads this for the derived artifact's ORAS provenance
            # layer; shipping without it silently is worse than failing here.
            log.error(f"derive '{variant}': failed exporting metadata.json")
            return err

        # tar/oci read the live mount; drop binds first so the rootfs view
        # is static (volatile /sys etc. trip tar's "file changed" check).
        if output in ("tar", "oci", "lxc"):
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
        if osr == "fedora":
            body = STRIP_SCRIPT_DNF
        else:
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
    """Tar the mounted rootfs; gzip it (wsl) or docker-import it (docker).

    Every shape routed here is stripped, so it must satisfy the rootfs contract
    (clean of kernel/bootloader/cloud-init, operator + metadata intact). Assert
    that first, so a broken strip fails the build before any artifact is packed
    (and so the wsl shape, which has no runtime check, is still validated)."""
    rc = _assert_rootfs_contract(cijoe, mnt, variant)
    if rc:
        return rc

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
        err, _ = cijoe.run_local(f"sha256sum {gz_path} > {gz_path}.sha256")
        if err:
            log.error(f"derive '{variant}': failed writing {gz_path}.sha256")
            return err
        tar_path.unlink(missing_ok=True)
        log.info(f"derive '{variant}': wrote {gz_path}")
        return 0

    if output == "lxc":
        # Proxmox CT / Incus system-container template: the same stripped
        # rootfs as wsl, packed as a zstd tarball (Proxmox's preferred CT
        # format, dropped straight into template/cache/ for `pct create`).
        # Validated under systemd-nspawn -- the systemd-PID1 shape a CT runs.
        tar_path = disk_dir / f"nosi-{variant}.tar"
        zst_path = disk_dir / f"nosi-{variant}.tar.zst"
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
        # Validate before compressing (the tar above already captured a clean
        # rootfs; nspawn may touch the mount, which is discarded after).
        rc = _nspawn_smoketest(cijoe, mnt, variant)
        if rc:
            tar_path.unlink(missing_ok=True)
            return rc
        err, _ = cijoe.run_local(f"zstd -19 -T0 -f -q -o {zst_path} {tar_path}")
        if err:
            log.error("zstd compression of CT tarball failed")
            return err
        err, _ = cijoe.run_local(f"sha256sum {zst_path} > {zst_path}.sha256")
        if err:
            log.error(f"derive '{variant}': failed writing {zst_path}.sha256")
            return err
        tar_path.unlink(missing_ok=True)
        log.info(f"derive '{variant}': wrote {zst_path} (Proxmox CT / Incus template)")
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


# Filesystem-contract assertion shared by every stripped shape (wsl / lxc /
# docker). Runs on the host against the mounted rootfs, so it is cheap (no
# container runtime) and catches what the per-shape runtime check cannot: a
# strip that silently failed to remove the kernel / modules / bootloader /
# cloud-init (a missed purge glob or a renamed package ships a bloated, wrong
# rootfs), and a derive that lost the operator account or the metadata file.
# `cd "$1"` then relative paths so a check can never escape the rootfs; $1 is
# the mount passed as an argv, not interpolated into the script body.
_ROOTFS_CONTRACT_CHECK = r"""
set -u
rc=0
fail() { echo "CONTRACT FAIL: $1"; rc=1; }
cd "$1" || { echo "CONTRACT FAIL: cannot cd into rootfs"; exit 2; }
# Strip worked: no kernel, modules, bootloader or cloud-init. These are
# meaningless without our own kernel and are exactly what bloats / breaks a
# container or WSL rootfs. rm -rf leaves the dirs but empties them, so test
# for emptiness rather than absence.
[ -z "$(ls -A boot 2>/dev/null)" ] || fail "/boot not empty (kernel/bootloader not stripped)"
[ -z "$(ls -A lib/modules 2>/dev/null)" ] || fail "/lib/modules not empty (modules not stripped)"
[ -z "$(ls -A usr/lib/modules 2>/dev/null)" ] || fail "/usr/lib/modules not empty"
[ ! -e etc/cloud ] || fail "/etc/cloud present (cloud-init not stripped)"
[ ! -e var/lib/cloud ] || fail "/var/lib/cloud present (cloud-init state not stripped)"
[ ! -e usr/local/bin/tailscale ] || fail "tailscale present (belongs to the host, not a container)"
# Contract intact: the metadata file, the operator account, and the upstream
# tools must all survive the strip.
[ -f etc/nosi-metadata.json ] || fail "/etc/nosi-metadata.json missing"
grep -q '^odus:' etc/passwd || fail "operator 'odus' missing from /etc/passwd"
[ -x usr/local/bin/hx ] || fail "/usr/local/bin/hx missing or not executable"
exit $rc
"""


def _assert_rootfs_contract(cijoe, mnt, variant) -> int:
    """Assert the stripped rootfs is container-clean and still carries the nosi
    contract, before it is tarred / imported. Shared by wsl / lxc / docker so a
    strip regression or a dropped operator/metadata fails the build rather than
    shipping a broken rootfs. Complements (does not replace) the per-shape
    runtime check, which proves the rootfs executes but not that it is clean."""
    err, _ = cijoe.run_local(f"sudo sh -c {_q(_ROOTFS_CONTRACT_CHECK)} nosi-contract {mnt}")
    if err:
        log.error(f"derive '{variant}': rootfs contract check failed (see CONTRACT FAIL lines)")
        return err
    log.info(f"derive '{variant}': rootfs contract check passed (stripped clean, contract intact)")
    return 0


def _nspawn_smoketest(cijoe, mnt, variant) -> int:
    """Run the stripped CT rootfs under systemd-nspawn and assert it is a
    complete container rootfs: systemd present (it is what a CT runs as PID 1),
    sshd present, and a sample upstream tool executes. Parity with the OCI
    shape's `docker run` check -- a namespaced run, not a full boot."""
    check = (
        "command -v systemctl >/dev/null "
        "&& { command -v sshd >/dev/null || test -x /usr/sbin/sshd; } "
        "&& /usr/local/bin/hx --version"
    )
    err, _ = cijoe.run_local(
        f"sudo systemd-nspawn -q --register=no -D {mnt} --pipe /bin/sh -c {_q(check)}"
    )
    if err:
        log.error(f"derive '{variant}': nspawn smoketest failed (rootfs not container-clean?)")
        return err
    log.info(f"derive '{variant}': nspawn smoketest passed")
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
    err, _ = cijoe.run_local(f"sha256sum {gz_path} > {gz_path}.sha256")
    if err:
        log.error(f"derive '{variant}': failed writing {gz_path}.sha256")
        return err
    raw_path.unlink(missing_ok=True)
    log.info(f"derive '{variant}': wrote {gz_path}")
    return 0


def _find_rootfs_partition(cijoe, work, attempts=10):
    """Largest ext4 / btrfs / xfs partition on NBD_DEV -- the rootfs
    (/boot, ESP, BIOS-boot are smaller or other fstypes). Cloud images
    differ by distro: Ubuntu / Debian ship ext4, Fedora ships btrfs,
    others ship xfs; pick the largest rootfs-capable filesystem.

    Only accept a candidate at least MIN_ROOTFS_BYTES: the partition nodes
    appear asynchronously after qemu-nbd connect, and a too-early lsblk can
    show a tiny reserved partition (e.g. a sub-GiB ext4 on nbd0p13) before the
    multi-GiB rootfs node settles -- picking it mounts a partition with no
    /etc/os-release and fails the derive. A nosi rootfs is always several GiB,
    so requiring >= 1 GiB filters the phantom and we retry until the real one
    is visible."""

    rootfs_fstypes = ("ext4", "btrfs", "xfs")
    min_rootfs_bytes = 1 << 30  # 1 GiB
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
                            if size is not None and int(size) >= min_rootfs_bytes:
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
