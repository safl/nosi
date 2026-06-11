"""Unit tests for cijoe/scripts/buildlib.py."""

from __future__ import annotations

import subprocess

import buildlib


class _FakeCijoe:
    def __init__(self, conf):
        self._conf = conf

    def getconf(self, key, default=None):
        return self._conf.get(key, default)


def test_default_image_name_from_config():
    cijoe = _FakeCijoe({"nosi": {"variant": "fedora-44-headless"}})
    assert buildlib.default_image_name(cijoe) == "nosi-fedora-44-headless-x86_64"


def test_default_image_name_arch_override():
    cijoe = _FakeCijoe({"nosi": {"variant": "rpios-13-headless"}})
    assert buildlib.default_image_name(cijoe, arch="arm64") == "nosi-rpios-13-headless-arm64"


def test_default_image_name_fallback():
    assert buildlib.default_image_name(_FakeCijoe({})) == "nosi-debian-13-headless-x86_64"


def test_gzip_cmd_is_a_real_compressor():
    assert buildlib.gzip_cmd() in ("pigz", "gzip")


def test_q_roundtrips_through_sh():
    # The quoting contract is "safe as a single sh word"; prove it by
    # round-tripping hostile input through a real shell.
    hostile = """a b'c"d$e`f;g&h|i\\j"""
    out = subprocess.run(
        ["sh", "-c", f"printf %s {buildlib.q(hostile)}"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    assert out == hostile
