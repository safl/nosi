"""Shared pytest setup for the nosi unit tests.

The build helpers are plain modules inside cijoe/scripts, tools and
docs/tooling/src rather than an installed package, so put those
directories on sys.path the same way their runtime environments do
(cijoe adds its scripts dir; the docs tooling is pipx-installed).
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent

for rel in ("cijoe/scripts", "tools", "docs/tooling/src"):
    p = str(REPO_ROOT / rel)
    if p not in sys.path:
        sys.path.insert(0, p)


@pytest.fixture
def repo_root() -> Path:
    return REPO_ROOT
