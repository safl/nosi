"""
Helpers shared by the cijoe build scripts
=========================================

Library module, not a runnable step (same convention as ``imgshrink``).
These replaced near-identical copy-pasted privates across the build
scripts; centralizing them means a fix lands everywhere they're imported.
(``rpi_image_build`` keeps its own ``_default_image_name`` with a Pi
default + fixed arm64, rather than importing this one.)

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
