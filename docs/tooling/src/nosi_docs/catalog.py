"""Fetch nosi image metadata from GHCR and render the docs/src/catalog/ tree.

The bake writes /etc/nosi-metadata.json inside the VM; the smoketest
scp's it out; the GHA push attaches it as an ORAS layer on each
ghcr.io/safl/nosi/<variant>:<rolling> tag (and the :latest alias).

This module pulls the metadata layer for every published variant and
renders a beautified catalog: a landing page (catalog/index.md) with a
summary table plus one page per variant (catalog/<name>/index.md) so the
docs stop maintaining parallel descriptions of
variants/distros/tools/packages: the ORAS artifact is the source of
truth.

Failure modes are tolerated. If oras isn't installed, the network is
down, or a variant has never been published yet, the per-variant
page renders a "(not yet published)" placeholder rather than
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
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import yaml

log = logging.getLogger(__name__)


GHCR_PREFIX = "ghcr.io/safl/nosi"


def known_variants(repo_root: Path) -> tuple[tuple[str, str, str], ...]:
    """(name, ref, shape) for every variant nosi publishes to GHCR.

    Derived from variants.yml -- the same registry that drives the build
    annotations and gen_catalog -- instead of a hand-maintained list here,
    which had already drifted seven variants behind the fleet once.

    The `docker` shape is included so the catalog covers every offering, but
    it is rendered differently: it is a `docker import` OCI image without the
    vnd.nosi.metadata.v1+json layer the other shapes carry, so its page is
    built from local sources (variants.yml + descriptions/<name>.md) and shows
    a `docker pull` flow rather than the oras-pull + dd flash flow."""
    data = yaml.safe_load((repo_root / "variants.yml").read_text())
    return tuple(
        (name, f"{GHCR_PREFIX}/{name}:latest", spec.get("shape") or "?")
        for name, spec in data["variants"].items()
    )


@dataclass
class VariantSnapshot:
    name: str
    ref: str
    shape: str = "?"
    metadata: dict | None = None
    error: str | None = None
    description: str | None = None  # from org.opencontainers.image.description


def fetch_and_render(docs_root: Path) -> Path:
    """Pull metadata for every variant, render the docs/src/catalog/ tree.

    Writes catalog/index.md (intro + summary table + a toctree) plus one
    catalog/<name>/index.md detail page per variant. Returns the path to
    the index page. Idempotent and side-effect-free apart from the network
    pulls and the files written.
    """
    out_dir = docs_root / "src" / "catalog"
    out_dir.mkdir(parents=True, exist_ok=True)

    repo_root = docs_root.resolve().parent
    variants = known_variants(repo_root)
    snapshots = [_fetch_variant(name, ref, shape, repo_root) for name, ref, shape in variants]

    for s in snapshots:
        variant_dir = out_dir / s.name
        variant_dir.mkdir(parents=True, exist_ok=True)
        (variant_dir / "index.md").write_text(_render_variant_page(s))

    index = out_dir / "index.md"
    index.write_text(_render_index(snapshots))

    ok = sum(1 for s in snapshots if s.metadata is not None)
    log.info(
        "nosi catalog: %d / %d variants rendered from GHCR -> %s",
        ok,
        len(snapshots),
        index,
    )
    return index


METADATA_MEDIA_TYPE = "application/vnd.nosi.metadata.v1+json"


def _local_description(repo_root: Path, name: str) -> str | None:
    """The variant's use-case prose from descriptions/<name>.md (the same file
    gen_catalog --describe feeds into the ORAS description annotation). Read
    locally for the docker shape, which carries no annotation to read back."""
    path = repo_root / "descriptions" / f"{name}.md"
    try:
        text = path.read_text().strip()
    except OSError:
        return None
    return text or None


def _fetch_variant(name: str, ref: str, shape: str, repo_root: Path) -> VariantSnapshot:
    """Fetch <ref>'s manifest, locate the metadata.v1+json layer, fetch the blob.

    Avoids the multi-GiB disk-image layer entirely (oras pull pre-1.3
    has no per-mediaType filter so a naive `oras pull` would download
    everything). manifest-fetch + blob-fetch hits only the bytes the
    catalog actually needs (~few KB per variant).

    The docker shape is a plain OCI image with no nosi metadata layer to fetch,
    so it is rendered from local sources instead: its description comes from
    descriptions/<name>.md and its page shows a `docker pull` flow. No network
    call, so it always renders.
    """
    snap = VariantSnapshot(name=name, ref=ref, shape=shape)
    if shape == "docker":
        snap.description = _local_description(repo_root, name)
        return snap
    if shutil.which("oras") is None:
        snap.error = "oras CLI not found on PATH"
        return snap
    try:
        # 1. Manifest fetch -- gives us the layer index + media types.
        mres = subprocess.run(
            ["oras", "manifest", "fetch", ref],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        manifest = json.loads(mres.stdout)
        # Per-variant use-case prose lives in the manifest's
        # org.opencontainers.image.description annotation (set by
        # .github/workflows/build.yml at push time). Surfaced in the
        # catalog so docs and ORAS consumers see the same string.
        snap.description = manifest.get("annotations", {}).get(
            "org.opencontainers.image.description"
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
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        snap.metadata = json.loads(bres.stdout)
    except subprocess.TimeoutExpired as exc:
        # A slow GHCR fetch must not kill the whole catalog build -- record it
        # as this variant's error and let the rest render, same as any other
        # per-variant fetch failure below.
        snap.error = f"oras fetch of {ref} timed out after {exc.timeout:.0f}s"
    except subprocess.CalledProcessError as exc:
        msg = (exc.stderr or exc.stdout or str(exc)).strip().splitlines()
        snap.error = msg[-1] if msg else str(exc)
    except (json.JSONDecodeError, OSError) as exc:
        snap.error = str(exc)
    return snap


# Furo reads the page-level hide-toc field from MyST front matter; setting
# it drops the right-hand "on this page" sidebar on the catalog pages.
_FRONT_MATTER = "---\nhide-toc: true\n---\n"


def _render_index(snapshots: Iterable[VariantSnapshot]) -> str:
    snaps = list(snapshots)
    lines = [
        _FRONT_MATTER.rstrip("\n"),
        "",
        "# Catalog",
        "",
        "Every nosi image published to "
        "[GHCR](https://github.com/safl/nosi/pkgs/container/nosi), listed here "
        "automatically. For the disk-image and rootfs shapes the fields below "
        "are read from the ORAS metadata layer that ships alongside each "
        "artifact; the docker shape is a plain OCI image (`docker pull`) so its "
        "page is built from its in-repo description. This page is regenerated "
        "on every docs build.",
        "",
        "## Summary",
        "",
        "| Variant | Distro | Shape | Kernel | Version | Built |",
        "|---|---|---|---|---|---|",
    ]
    for s in snaps:
        if s.shape == "docker":
            # OCI image: no metadata layer, and no kernel (stripped). The page
            # carries the description + `docker pull` flow.
            lines.append(
                f"| [`{s.name}`]({s.name}/index.md) | _OCI image_ | docker "
                "| _none (stripped)_ | _see image_ | _rolling_ |"
            )
            continue
        if s.metadata is None:
            lines.append(f"| [`{s.name}`]({s.name}/index.md) | _(not yet published)_ | | | | |")
            continue
        m = s.metadata
        n = m.get("nosi", {}) or {}
        d = m.get("distro", {}) or {}
        k = m.get("kernel", {}) or {}
        lines.append(
            f"| [`{s.name}`]({s.name}/index.md) "
            f"| {d.get('pretty_name') or '?'} "
            f"| {n.get('shape') or '?'} "
            f"| {k.get('release') or '?'} "
            f"| `{n.get('version') or '?'}` "
            f"| {n.get('built') or '?'} |"
        )
    lines.extend(["", "```{toctree}", ":maxdepth: 1", ""])
    lines.extend(f"{s.name}/index" for s in snaps)
    lines.append("```")
    return "\n".join(lines) + "\n"


def _render_docker_page(s: VariantSnapshot) -> str:
    """Page for the docker shape: a plain OCI image, so a `docker pull` + run
    flow rather than the oras-pull + dd flash the disk-image shapes render."""
    parts: list[str] = [_FRONT_MATTER.rstrip("\n"), "", f"# `{s.name}`", ""]
    if s.description:
        parts.extend([s.description, ""])
    parts.extend(
        [
            "**Shape:** `docker` (OCI image)  ",
            "**Architecture:** `x86_64`  ",
            "**Kernel:** _none: kernel / boot / cloud-init stripped_  ",
            "**Tag:** rolling `:latest` (plus a dated rolling tag per build)",
            "",
            "## Pull and run",
            "",
            "```",
            f"docker pull {s.ref}",
            "```",
            "",
            "Use it as a GitHub Actions job container:",
            "",
            "```yaml",
            "jobs:",
            "  build:",
            f"    container: {s.ref}",
            "```",
            "",
            "Or launch a guest with the bundled qemu + cijoe (nested KVM needs "
            "`--privileged` or a passed-through `/dev/kvm`):",
            "",
            "```",
            f"docker run --rm -it --privileged {s.ref}",
            "```",
            "",
            "The tooling matches the headless base it derives from; see that "
            "variant's page for the full tool and package inventory.",
            "",
        ]
    )
    return "\n".join(parts)


def _render_variant_page(s: VariantSnapshot) -> str:
    if s.shape == "docker":
        return _render_docker_page(s)
    if s.metadata is None:
        return (
            f"{_FRONT_MATTER}\n"
            f"# `{s.name}`\n\n"
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
    parts: list[str] = [_FRONT_MATTER.rstrip("\n"), "", f"# `{s.name}`", ""]
    if s.description:
        # Per-variant use-case prose from the ORAS manifest annotation.
        # First paragraph of the variant section so "what is this for?"
        # precedes "what's inside?".
        parts.extend([s.description, ""])
    parts.extend(
        [
            f"**Distro:** {d.get('pretty_name') or '?'}  ",
            f"**Shape:** `{n.get('shape') or '?'}`  ",
            f"**Kernel:** `{k.get('release') or '?'}`  ",
            f"**Architecture:** `{arch}`  ",
            f"**Version:** `{n.get('version') or '?'}`  ",
            f"**Built:** {n.get('built') or '?'}",
            "",
            "## Pull and flash",
            "",
            "```",
            f"oras pull {s.ref}",
            f"gunzip -dc nosi-{s.name}-x86_64.img.gz \\",
            "    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress",
            "```",
            "",
            "## Default credentials",
            "",
            f"- **Username:** `{op.get('username') or 'odus'}` (uid {op.get('uid') or 1000})",
            f"- **Password:** `{op.get('default_password') or 'odus.321'}`",
        ]
    )
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
        parts.append(f"## {label}")
        parts.append("")
        parts.append("| Tool | Version |")
        parts.append("|---|---|")
        for tname, tver in sorted(tdict.items()):
            parts.append(f"| `{tname}` | `{tver}` |" if tver else f"| `{tname}` | _(missing)_ |")
        parts.append("")

    manual = pkgs.get("manually_installed") or []
    if manual:
        parts.append(
            f"## Installed packages ({pkgs.get('count') or len(manual)} via "
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

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    cwd = Path.cwd()
    for candidate in (cwd, cwd.parent):
        if (candidate / "src" / "conf.py").exists():
            fetch_and_render(candidate)
            return
    sys.exit("nosi-docs-fetch-catalog: run from the docs/ directory")
