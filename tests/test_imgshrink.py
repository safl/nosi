"""Unit tests for imgshrink's parsers + sector arithmetic.

imgshrink shells out (resize2fs / btrfs / sfdisk / lsblk) and parses the
text/JSON back with regexes, then does 512-byte-sector math. That parse +
arithmetic is the most failure-prone code in the build path and was
untested. FakeCijoe stands in for cijoe: it intercepts the `> <path>`
redirect each helper uses and drops canned tool output there, so the real
function (regex + math) runs end to end without touching a real disk.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import imgshrink


class FakeCijoe:
    """Minimal cijoe stand-in. `writes` is a list of (substr, content): when a
    run_local command contains substr and redirects stdout to a file
    (`> path`), that file is filled with content, mimicking the tool's output.
    Every call returns (0, None) unless `errs` maps a substr to a non-zero code.
    """

    def __init__(self, writes=None, errs=None):
        self.writes = writes or []
        self.errs = errs or []
        self.calls = []

    def run_local(self, cmd, *args, **kwargs):
        self.calls.append(cmd)
        for substr, content in self.writes:
            if substr in cmd:
                m = re.search(r">\s+(\S+)", cmd)  # the `> path` stdout redirect
                if m:
                    Path(m.group(1)).write_text(content)
                break
        err = 0
        for substr, code in self.errs:
            if substr in cmd:
                err = code
                break
        return (err, None)


# ---- resize2fs minimize parsing -------------------------------------------


def test_resize2fs_minimize_parses_now_line():
    cj = FakeCijoe(
        writes=[("resize2fs -M", "The filesystem ... is now 524288 (4k) blocks long.\n")]
    )
    assert imgshrink._resize2fs_minimize(cj, "/dev/loop0p2") == 524288


def test_resize2fs_minimize_parses_already_line():
    cj = FakeCijoe(
        writes=[("resize2fs -M", "The filesystem is already 600000 (4k) blocks long.\n")]
    )
    assert imgshrink._resize2fs_minimize(cj, "/dev/loop0p2") == 600000


def test_resize2fs_minimize_falls_back_to_estimate():
    cj = FakeCijoe(writes=[("resize2fs -M", "Estimated minimum size of the filesystem: 480000\n")])
    assert imgshrink._resize2fs_minimize(cj, "/dev/loop0p2") == 480000


def test_resize2fs_minimize_unparseable_is_none():
    cj = FakeCijoe(writes=[("resize2fs -M", "resize2fs: Permission denied\n")])
    assert imgshrink._resize2fs_minimize(cj, "/dev/loop0p2") is None


def test_shrink_ext4_adds_slack_and_converts_to_sectors():
    cj = FakeCijoe(writes=[("resize2fs -M", "is now 524288 (4k) blocks long.\n")])
    # min_blocks + 65536 (256 MiB slack), each 4 KiB block = 8 sectors.
    assert imgshrink._shrink_ext4(cj, "/dev/loop0p2") == (524288 + 65536) * 8


def test_shrink_ext4_none_when_minimize_fails():
    cj = FakeCijoe(writes=[("resize2fs -M", "garbage\n")])
    assert imgshrink._shrink_ext4(cj, "/dev/loop0p2") is None


# ---- btrfs used-bytes + shrink target -------------------------------------


def test_btrfs_used_bytes_parses_overall_used():
    usage = "Overall:\n    Device size:  12884901888\n    Used:  1500000000\n"
    cj = FakeCijoe(writes=[("btrfs filesystem usage", usage)])
    assert imgshrink._btrfs_used_bytes(cj, Path("/mnt/x")) == 1500000000


def test_shrink_btrfs_target_is_used_plus_1gib_mib_aligned():
    used = 1500000000
    cj = FakeCijoe(writes=[("btrfs filesystem usage", f"Overall:\n    Used: {used}\n")])
    mib = 1 << 20
    target = (used + (1 << 30) + mib - 1) // mib * mib
    assert imgshrink._shrink_btrfs(cj, "/dev/loop0p2") == target // 512


# ---- sfdisk partition start -----------------------------------------------


def test_part_start_parses_correct_partition():
    sfdisk = (
        "label: gpt\nunit: sectors\n\n"
        "/dev/loop0p1 : start=        2048, size=      204800, type=C12A...\n"
        "/dev/loop0p2 : start=      206848, size=    24000000, type=0FC6...\n"
    )
    cj = FakeCijoe(writes=[("sfdisk -d", sfdisk)])
    assert imgshrink._part_start(cj, "/dev/loop0", "2") == 206848
    assert imgshrink._part_start(cj, "/dev/loop0", "1") == 2048


def test_part_start_missing_partition_is_none():
    cj = FakeCijoe(writes=[("sfdisk -d", "label: gpt\n/dev/loop0p1 : start=2048, size=1\n")])
    assert imgshrink._part_start(cj, "/dev/loop0", "9") is None


# ---- lsblk rootfs selection ------------------------------------------------


def test_rootfs_picks_largest_linux_fs_and_ignores_esp():
    lsblk = json.dumps(
        {
            "blockdevices": [
                {
                    "name": "loop0",
                    "fstype": None,
                    "size": 12884901888,
                    "type": "loop",
                    "pttype": "gpt",
                    "children": [
                        {
                            "name": "loop0p1",
                            "fstype": "vfat",
                            "size": 134217728,
                            "type": "part",
                            "pttype": "gpt",
                        },
                        {
                            "name": "loop0p2",
                            "fstype": "ext4",
                            "size": 12700000000,
                            "type": "part",
                            "pttype": "gpt",
                        },
                    ],
                }
            ]
        }
    )
    cj = FakeCijoe(writes=[("lsblk -J", lsblk)])
    assert imgshrink._rootfs(cj, "/dev/loop0") == ("/dev/loop0p2", "ext4", "gpt")


def test_rootfs_none_when_no_linux_filesystem():
    lsblk = json.dumps(
        {
            "blockdevices": [
                {
                    "name": "loop0",
                    "type": "loop",
                    "pttype": "dos",
                    "children": [
                        {
                            "name": "loop0p1",
                            "fstype": "vfat",
                            "size": 100,
                            "type": "part",
                            "pttype": "dos",
                        },
                    ],
                }
            ]
        }
    )
    cj = FakeCijoe(writes=[("lsblk -J", lsblk)])
    assert imgshrink._rootfs(cj, "/dev/loop0") == (None, None, "dos")
