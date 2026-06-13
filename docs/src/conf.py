"""Sphinx configuration for nosi documentation."""

from __future__ import annotations

project = "nosi"
author = "Simon A. F. Lund"
copyright = f"2026, {author}"

extensions = [
    "myst_parser",
    "sphinx_copybutton",
]

myst_enable_extensions = [
    "deflist",
    "fieldlist",
    "tasklist",
    "linkify",
    "colon_fence",
]

source_suffix = {".md": "markdown"}
master_doc = "index"

templates_path = ["_templates"]
exclude_patterns: list[str] = ["_build", "Thumbs.db", ".DS_Store"]

html_theme = "furo"
# Furo renders html_logo in the sidebar header where html_title would
# otherwise sit. Leaving html_title empty suppresses the redundant
# "nosi -- Nic(h)e Operating System Images" wordmark there, since the
# logo already includes the "nosi" wordmark and the index.md H1 carries
# the long-form name on the landing page.
html_title = ""
# Sidebar header logo: a 480px-wide downscale of the ~2 MB source (nosi.png),
# which Furo renders at ~200px. Pointing html_logo at the original made every
# page pull the full-resolution image; nosi-logo.png is ~12x smaller and still
# retina-crisp at the rendered size. The full-res nosi.png stays for the README
# hero and as the source to regenerate this from.
html_logo = "_static/nosi-logo.png"
# Browser-tab icon: a 180px square crop of the floppy-disk logo. Pointing
# this at nosi.png directly would make every page pull the ~2 MB original.
html_favicon = "_static/favicon.png"
html_static_path = ["_static"]
