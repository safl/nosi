"""Fetch nosi image metadata from GHCR and render docs/src/_generated/catalog.md.

The bake writes /etc/nosi-metadata.json inside the VM; the smoketest
scp's it out; the GHA push attaches it as an ORAS layer on each
ghcr.io/safl/nosi/<variant>:<rolling> tag (and the :latest alias).

This module pulls the metadata layer for every published variant and
renders a single beautified catalog page so the docs stop maintaining
parallel descriptions of variants/distros/tools/packages: the ORAS
artefact is the source of truth.

Failure modes are tolerated. If oras isn't installed, the network is
down, or a variant has never been published yet, the per-variant
section renders a "(not yet published)" placeholder rather than
breaking the docs build.

Caching is intentionally not implemented; each docs build pulls fresh
metadata. Adding a cache would mean answering "how do we invalidate?"
and that question is the docs author's problem, not the renderer's.
"""

from __future__ import annotations

import json
import logging
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

log = logging.getLogger(__name__)


# Variants nosi publishes. Keep in sync with .github/workflows/build.yml's
# matrix.variant list and the cijoe/configs/ directory.
KNOWN_VARIANTS: tuple[tuple[str, str], ...] = (
    ("debian-13-headless",   "ghcr.io/safl/nosi/debian-13-headless:latest"),
    ("ubuntu-2404-headless", "ghcr.io/safl/nosi/ubuntu-2404-headless:latest"),
    ("ubuntu-2604-headless", "ghcr.io/safl/nosi/ubuntu-2604-headless:latest"),
    ("ubuntu-2604-wsl",      "ghcr.io/safl/nosi/ubuntu-2604-wsl:latest"),
    ("fedora-44-headless",   "ghcr.io/safl/nosi/fedora-44-headless:latest"),
    ("fedora-44-desktop",    "ghcr.io/safl/nosi/fedora-44-desktop:latest"),
    ("freebsd-14-headless",  "ghcr.io/safl/nosi/freebsd-14-headless:latest"),
    ("freebsd-15-headless",  "ghcr.io/safl/nosi/freebsd-15-headless:latest"),
)


@dataclass
class VariantSnapshot:
    name: str
    ref: str
    metadata: dict | None = None
    error: str | None = None
    description: str | None = None  # from org.opencontainers.image.description


def fetch_and_render(docs_root: Path) -> Path:
    """Pull metadata for every variant, render docs/src/_generated/catalog.md.

    Returns the path to the generated file. Idempotent and side-effect-
    free apart from the network pulls and the one file written.
    """
    out_dir = docs_root / "src" / "_generated"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "catalog.md"

    snapshots = [_fetch_variant(name, ref) for name, ref in KNOWN_VARIANTS]
    rendered = _render(snapshots)
    out.write_text(rendered)
    ok = sum(1 for s in snapshots if s.metadata is not None)
    log.info("nosi catalog: %d / %d variants rendered from GHCR -> %s",
             ok, len(snapshots), out)
    return out


METADATA_MEDIA_TYPE = "application/vnd.nosi.metadata.v1+json"


def _fetch_variant(name: str, ref: str) -> VariantSnapshot:
    """Fetch <ref>'s manifest, locate the metadata.v1+json layer, fetch the blob.

    Avoids the multi-GiB disk-image layer entirely (oras pull pre-1.3
    has no per-mediaType filter so a naive `oras pull` would download
    everything). manifest-fetch + blob-fetch hits only the bytes the
    catalog actually needs (~few KB per variant).
    """
    snap = VariantSnapshot(name=name, ref=ref)
    if shutil.which("oras") is None:
        snap.error = "oras CLI not found on PATH"
        return snap
    try:
        # 1. Manifest fetch -- gives us the layer index + media types.
        mres = subprocess.run(
            ["oras", "manifest", "fetch", ref],
            check=True, capture_output=True, text=True, timeout=60,
        )
        manifest = json.loads(mres.stdout)
        # Per-variant use-case prose lives in the manifest's
        # org.opencontainers.image.description annotation (set by
        # .github/workflows/build.yml at push time). Surfaced in the
        # catalog so docs and ORAS consumers see the same string.
        snap.description = (
            manifest.get("annotations", {})
            .get("org.opencontainers.image.description")
        )
        digest = None
        for layer in manifest.get("layers", []):
            if layer.get("mediaType") == METADATA_MEDIA_TYPE:
                digest = layer.get("digest")
                break
        if digest is None:
            snap.error = f"no {METADATA_MEDIA_TYPE} layer in manifest"
            return snap
        # 2. Blob fetch -- the metadata.json bytes themselves.
        # The repo part of the ref is everything before the tag; oras
        # blob fetch wants <repo>@<digest>.
        repo = ref.rsplit(":", 1)[0] if ":" in ref.rsplit("/", 1)[-1] else ref
        bres = subprocess.run(
            ["oras", "blob", "fetch", "--output", "-", f"{repo}@{digest}"],
            check=True, capture_output=True, text=True, timeout=60,
        )
        snap.metadata = json.loads(bres.stdout)
    except subprocess.CalledProcessError as exc:
        msg = (exc.stderr or exc.stdout or str(exc)).strip().splitlines()
        snap.error = msg[-1] if msg else str(exc)
    except (json.JSONDecodeError, OSError) as exc:
        snap.error = str(exc)
    return snap


def _render(snapshots: Iterable[VariantSnapshot]) -> str:
    snaps = list(snapshots)
    lines = [
        "# Catalog",
        "",
        "Every nosi image published to "
        "[GHCR](https://github.com/safl/nosi/pkgs/container/nosi), listed here "
        "automatically from the ORAS metadata layer that ships alongside each "
        ".img.gz. The fields below are read directly from the baked image at "
        "publish time; this page is regenerated on every docs build.",
        "",
        "## Summary",
        "",
        "| Variant | Distro | Shape | Kernel | Version | Built |",
        "|---|---|---|---|---|---|",
    ]
    for s in snaps:
        if s.metadata is None:
            lines.append(
                f"| `{s.name}` | _(not yet published)_ | | | | |"
            )
            continue
        m = s.metadata
        n = m.get("nosi", {}) or {}
        d = m.get("distro", {}) or {}
        k = m.get("kernel", {}) or {}
        lines.append(
            f"| `{s.name}` "
            f"| {d.get('pretty_name') or '?'} "
            f"| {n.get('shape') or n.get('flavor') or '?'} "
            f"| {k.get('release') or '?'} "
            f"| `{n.get('version') or '?'}` "
            f"| {n.get('built') or '?'} |"
        )
    lines.append("")
    for s in snaps:
        lines.append(_render_variant_section(s))
        lines.append("")
    return "\n".join(lines) + "\n"


def _render_variant_section(s: VariantSnapshot) -> str:
    if s.metadata is None:
        return (
            f"## `{s.name}`\n\n"
            f"_Not yet published. The pull ref `{s.ref}` is reserved._ "
            f"Catalog fetch error: `{s.error or 'unknown'}`.\n"
        )
    m = s.metadata
    n = m.get("nosi", {}) or {}
    d = m.get("distro", {}) or {}
    k = m.get("kernel", {}) or {}
    op = m.get("operator", {}) or {}
    tools = m.get("tools", {}) or {}
    pkgs = m.get("packages", {}) or {}

    arch = m.get("architecture") or "?"
    parts: list[str] = [f"## `{s.name}`", ""]
    if s.description:
        # Per-variant use-case prose from the ORAS manifest annotation.
        # First paragraph of the variant section so "what is this for?"
        # precedes "what's inside?".
        parts.extend([s.description, ""])
    parts.extend([
        f"**Distro:** {d.get('pretty_name') or '?'}  ",
        f"**Shape:** `{n.get('shape') or n.get('flavor') or '?'}`  ",
        f"**Kernel:** `{k.get('release') or '?'}`  ",
        f"**Architecture:** `{arch}`  ",
        f"**Version:** `{n.get('version') or '?'}`  ",
        f"**Built:** {n.get('built') or '?'}",
        "",
        "### Pull and flash",
        "",
        "```",
        f"oras pull {s.ref}",
        f"gunzip -dc nosi-{s.name}-x86_64.img.gz \\",
        "    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress",
        "```",
        "",
        "### Default credentials",
        "",
        f"- **Username:** `{op.get('username') or 'odus'}` (uid {op.get('uid') or 1000})",
        f"- **Password:** `{op.get('default_password') or 'odus.321'}`",
    ])
    state = op.get("default_password_state")
    if state:
        parts.append(f"- **Default-password state:** {state}")
    parts.append(f"- **Root login:** {'locked' if op.get('root_locked') else 'unlocked'}")
    ssh = op.get("ssh") or {}
    if ssh:
        parts.append(
            f"- **SSH:** password_auth={ssh.get('password_auth', '?')}, "
            f"permit_root_login={ssh.get('permit_root_login', '?')}"
        )
    parts.append("")

    for label, key in (
        ("Upstream-release tools", "upstream_releases"),
        ("Python CLIs via pipx", "pipx_global"),
    ):
        tdict = tools.get(key) or {}
        if not tdict:
            continue
        parts.append(f"### {label}")
        parts.append("")
        parts.append("| Tool | Version |")
        parts.append("|---|---|")
        for tname, tver in sorted(tdict.items()):
            parts.append(f"| `{tname}` | `{tver}` |" if tver else f"| `{tname}` | _(missing)_ |")
        parts.append("")

    manual = pkgs.get("manually_installed") or []
    if manual:
        parts.append(
            f"### Installed packages ({pkgs.get('count') or len(manual)} via "
            f"`{pkgs.get('manager') or '?'}`)"
        )
        parts.append("")
        parts.append(
            "<details><summary>Click to expand</summary>\n\n"
            + ", ".join(f"`{p}`" for p in manual)
            + "\n\n</details>"
        )
        parts.append("")
    return "\n".join(parts)


def cli() -> None:
    """Console-script entry point: `nosi-docs-fetch-catalog`."""
    import sys
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    cwd = Path.cwd()
    for candidate in (cwd, cwd.parent):
        if (candidate / "src" / "conf.py").exists():
            fetch_and_render(candidate)
            return
    sys.exit("nosi-docs-fetch-catalog: run from the docs/ directory")
