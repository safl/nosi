"""Console-script entry points for the nosi docs tooling."""

from __future__ import annotations

import logging
import subprocess
import sys
from pathlib import Path

from . import catalog as _catalog


def _docs_root() -> Path:
    """Locate the docs root: the directory containing ``src/conf.py``.

    The commands are expected to run from inside ``nosi/docs/`` (the
    directory holding this ``tooling/`` package and the ``src/`` Sphinx
    tree). Falls back to checking the parent in case the user invoked
    from ``nosi/docs/tooling``.
    """
    cwd = Path.cwd()
    for candidate in (cwd, cwd.parent):
        if (candidate / "src" / "conf.py").exists():
            return candidate
    sys.exit(
        "nosi-docs: could not find src/conf.py -- run from the docs directory (e.g. nosi/docs)"
    )


def _refresh_catalog(root: Path) -> None:
    """Pull current image metadata from GHCR and render the catalog page.

    Called automatically before every html/pdf build so the catalog
    reflects the latest published images. Non-fatal: a network failure
    or missing oras CLI leaves the previous _generated/catalog.md in
    place (or renders a placeholder for variants that fail to fetch).
    """
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    _catalog.fetch_and_render(root)


def build_html() -> None:
    root = _docs_root()
    _refresh_catalog(root)
    src = root / "src"
    out = root / "_build" / "html"
    subprocess.run(
        [sys.executable, "-m", "sphinx", "-W", "-b", "html", str(src), str(out)],
        check=True,
    )


def build_pdf() -> None:
    root = _docs_root()
    _refresh_catalog(root)
    src = root / "src"
    latex_out = root / "_build" / "latex"
    subprocess.run(
        [sys.executable, "-m", "sphinx", "-b", "latex", str(src), str(latex_out)],
        check=True,
    )
    subprocess.run(["make"], cwd=latex_out, check=True)


def serve() -> None:
    root = _docs_root()
    _refresh_catalog(root)
    src = root / "src"
    out = root / "_build" / "html"
    subprocess.run(
        [
            sys.executable,
            "-m",
            "sphinx_autobuild",
            "--port",
            "8000",
            str(src),
            str(out),
        ],
        check=True,
    )
