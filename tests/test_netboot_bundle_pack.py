"""Unit tests for cijoe/scripts/netboot_bundle_pack.py."""

from __future__ import annotations

from pathlib import Path

import netboot_bundle_pack as pack
import pytest


def _make_boot(candidate: Path, kernels: list[str], initrds: list[str]) -> None:
    candidate.mkdir(parents=True, exist_ok=True)
    for name in (*kernels, *initrds):
        (candidate / name).write_bytes(b"\0")


def test_find_boot_dir_debian_shape(tmp_path: Path):
    # Debian / initramfs-tools name shape: root partition carries /boot,
    # kernels sit at <root>/boot/vmlinuz-KVER + initrd.img-KVER.
    mount_root = tmp_path / "mnt"
    root_part = mount_root / "nbd0p1"
    boot = root_part / "boot"
    _make_boot(boot, ["vmlinuz-6.12.0-amd64"], ["initrd.img-6.12.0-amd64"])

    boot_dir, kver, initrd = pack._find_boot_dir(mount_root)

    assert boot_dir == boot
    assert kver == "6.12.0-amd64"
    assert initrd == boot / "initrd.img-6.12.0-amd64"


def test_find_boot_dir_fedora_shape(tmp_path: Path):
    # Separate /boot partition, dracut filename shape.
    mount_root = tmp_path / "mnt"
    boot_part = mount_root / "nbd0p2"
    _make_boot(
        boot_part,
        ["vmlinuz-6.16.5-200.fc44.x86_64"],
        ["initramfs-6.16.5-200.fc44.x86_64.img"],
    )

    boot_dir, kver, initrd = pack._find_boot_dir(mount_root)

    assert boot_dir == boot_part
    assert kver == "6.16.5-200.fc44.x86_64"
    assert initrd == boot_part / "initramfs-6.16.5-200.fc44.x86_64.img"


def test_find_boot_dir_ubuntu_2604_initrdimg_shape(tmp_path: Path):
    # Ubuntu 26.04 quirk: dracut wrote the initrd, but ``update-initramfs``
    # named the file ``initrd.img-<KVER>``. _find_boot_dir must NOT infer
    # framework from that filename; it just returns the file it found.
    # (Framework is decided later by _detect_framework_and_strip_dracut,
    # from the actual initrd contents.)
    mount_root = tmp_path / "mnt"
    root_part = mount_root / "nbd0p1"
    boot = root_part / "boot"
    _make_boot(boot, ["vmlinuz-6.14.0-1005-generic"], ["initrd.img-6.14.0-1005-generic"])

    boot_dir, kver, initrd = pack._find_boot_dir(mount_root)

    assert boot_dir == boot
    assert kver == "6.14.0-1005-generic"
    # Content-based detection is a separate step; _find_boot_dir returns
    # the initrd file, not a framework label.
    assert initrd.name == "initrd.img-6.14.0-1005-generic"


def test_find_boot_dir_picks_highest_kver(tmp_path: Path):
    # Cloud images occasionally leave the base kernel + a package-manager
    # kernel side by side; the packer must ship the newer one.
    mount_root = tmp_path / "mnt"
    root_part = mount_root / "nbd0p1"
    boot = root_part / "boot"
    _make_boot(
        boot,
        ["vmlinuz-6.1.0-13-amd64", "vmlinuz-6.1.0-27-amd64"],
        ["initrd.img-6.1.0-13-amd64", "initrd.img-6.1.0-27-amd64"],
    )

    _, kver, initrd = pack._find_boot_dir(mount_root)

    assert kver == "6.1.0-27-amd64"
    assert initrd.name == "initrd.img-6.1.0-27-amd64"


def test_find_boot_dir_no_match_raises(tmp_path: Path):
    mount_root = tmp_path / "mnt"
    empty = mount_root / "nbd0p1"
    empty.mkdir(parents=True)

    with pytest.raises(FileNotFoundError):
        pack._find_boot_dir(mount_root)


class _FakeCijoe:
    """Records shell commands + serves scripted returncodes.

    ``run_local`` returns (err, state) where err is 0/None on success
    and non-zero on failure, matching the actual cijoe surface used
    by netboot_bundle_pack.
    """

    def __init__(self, returncodes: dict[str, int] | None = None):
        self.calls: list[str] = []
        self._codes = returncodes or {}

    def run_local(self, cmd: str):
        self.calls.append(cmd)
        for needle, rc in self._codes.items():
            if needle in cmd:
                return rc, None
        return 0, None


def test_detect_framework_returns_initramfs_tools_when_unpack_fails(tmp_path: Path):
    # unmkinitramfs failing (e.g. binary missing on the runner) must not
    # crash the pack step; caller falls back to the safe default.
    initrd = tmp_path / "initrd"
    initrd.write_bytes(b"\0")
    cijoe = _FakeCijoe(returncodes={"unmkinitramfs": 1})

    framework = pack._detect_framework_and_strip_dracut(cijoe, initrd)

    assert framework == "initramfs-tools"
