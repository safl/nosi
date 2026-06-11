"""
Helpers shared by the cijoe build scripts
=========================================

Library module, not a runnable step (same convention as ``imgshrink``).
These existed as identical copy-pasted privates in four scripts; they live
here once so a fix lands everywhere.

Retargetable: False
"""

from __future__ import annotations

import shutil


def default_image_name(cijoe, arch: str = "x86_64") -> str:
    """``nosi-<variant>-<arch>`` from ``[nosi].variant`` in the cijoe config."""
    nosi = cijoe.getconf("nosi", {})
    return f"nosi-{nosi.get('variant', 'debian-13-headless')}-{arch}"


def gzip_cmd() -> str:
    """pigz when present (parallel, all cores; same .gz format), else gzip."""
    return "pigz" if shutil.which("pigz") else "gzip"


def q(s: str) -> str:
    """Single-quote a string for `sh -c`."""
    return "'" + s.replace("'", "'\\''") + "'"
