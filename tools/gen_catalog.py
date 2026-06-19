#!/usr/bin/env python3
"""Generate a bty-compatible ``catalog.toml`` from ``variants.yml``.

Two jobs over two sources: ``variants.yml`` (structured per-variant metadata:
shape / flashable / arch) and ``descriptions/<name>.md`` (one file per variant
holding its use-case prose; ``descriptions/<name>.wsl.md`` for the wsl shape's
separate rootfs blurb):

1. ``--describe <variant>`` / ``--describe-wsl <variant>``: print one
   variant's use-case prose. ``.github/workflows/build.yml`` calls these
   in its ORAS push steps so the ``org.opencontainers.image.description``
   annotation comes from the registry rather than an inline bash case.

2. ``--ref-tag <tag> [output]``: emit a ``catalog.toml`` listing every
   ``flashable: true`` variant as an ``oras://`` entry pinned to
   ``:<ref-tag>``. The build workflow generates BOTH files per release
   and uploads them as assets:

       gen_catalog.py --ref-tag "${ROLLING}" catalog.toml         # pinned
       gen_catalog.py --ref-tag latest      catalog-latest.toml   # rolling

   Operators point bty at one of:

       https://github.com/safl/nosi/releases/download/<ROLLING>/catalog.toml
       https://github.com/safl/nosi/releases/latest/download/catalog.toml
       https://github.com/safl/nosi/releases/latest/download/catalog-latest.toml

The catalog is schema v1 (``bty.catalog``). The wsl rootfs is deliberately
excluded (``flashable: false``): it is imported via ``wsl --import``, not
flashed to a block device, so it has no place in a flashable catalog.

Unknown / mis-registered variants fail loud (non-zero exit, message on
stderr) rather than emitting a placeholder. A baked-but-unregistered
variant should break the push, not ship a generic description.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
REGISTRY_PATH = REPO_ROOT / "variants.yml"
# Per-variant use-case prose, one file each: descriptions/<name>.md for the
# image description, descriptions/<name>.wsl.md for the wsl shape's separate
# rootfs blurb. Kept out of variants.yml so the registry stays pure structured
# metadata and each description can be edited / reviewed on its own.
DESCRIPTIONS_DIR = REPO_ROOT / "descriptions"

# GHCR namespace the build workflow pushes each variant to
# (ghcr.io/<owner>/<repo>/<variant>). Kept in lockstep with build.yml's
# ${REPO}; a constant here because the catalog is published for the
# canonical repo, not a fork.
ORAS_NAMESPACE = "ghcr.io/safl/nosi"


def _load_registry() -> dict[str, dict]:
    raw = yaml.safe_load(REGISTRY_PATH.read_text(encoding="utf-8"))
    variants = raw.get("variants") if isinstance(raw, dict) else None
    if not isinstance(variants, dict) or not variants:
        raise SystemExit(f"{REGISTRY_PATH}: missing or empty ``variants`` mapping")
    return variants


def _variant(variants: dict[str, dict], name: str) -> dict:
    try:
        return variants[name]
    except KeyError:
        raise SystemExit(
            f"variant {name!r} is not registered in {REGISTRY_PATH}; "
            f"add it there (known: {', '.join(sorted(variants))})"
        ) from None


def _load_description(name: str, *, wsl: bool = False) -> str:
    """Read a variant's use-case prose from its own file.

    Whitespace is collapsed to a single line, so a file wrapped for
    readability still yields the exact single-line string the ORAS
    image.description annotation and the catalog.toml entry expect.
    """
    path = DESCRIPTIONS_DIR / f"{name}{'.wsl.md' if wsl else '.md'}"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        raise SystemExit(f"variant {name!r}: missing description file {path}") from None
    collapsed = " ".join(text.split())
    if not collapsed:
        raise SystemExit(f"variant {name!r}: description file {path} is empty")
    return collapsed


def _describe(variants: dict[str, dict], name: str, *, key: str) -> str:
    # Validate the variant is registered first, so an unknown name fails with
    # the registry hint rather than a bare missing-file error.
    _variant(variants, name)
    return _load_description(name, wsl=(key == "wsl_description"))


def _toml_escape(text: str) -> str:
    """Escape a string for a TOML basic (double-quoted) value."""
    return text.replace("\\", "\\\\").replace('"', '\\"')


def _render_catalog(variants: dict[str, dict], ref_tag: str) -> str:
    """Render a catalog.toml. ``ref_tag`` is the oras tag baked into
    every image's ``src`` (e.g. ``latest`` for the rolling escape
    hatch, or a dated release tag like ``2026.06.16-7cf3895`` for a
    frozen, content-pinned catalog).

    The build workflow generates BOTH per release: ``catalog.toml``
    with ``ref_tag=<rolling>`` (pinned to the release's dated tag) and
    ``catalog-latest.toml`` with ``ref_tag=latest`` (always rolls).
    Operators wanting reproducible flashes use ``catalog.toml`` (any
    release); operators wanting whatever ghcr currently serves use
    ``catalog-latest.toml``.
    """
    is_rolling = ref_tag == "latest"
    label = "rolling" if is_rolling else ref_tag
    if is_rolling:
        header = [
            "# nosi image catalog, bty-compatible (schema v1). Generated from",
            "# variants.yml by tools/gen_catalog.py and published as a GitHub",
            "# release asset:",
            "#",
            "#   https://github.com/safl/nosi/releases/latest/download/catalog-latest.toml",
            "#",
            "# Point bty at it:",
            "#",
            "#   bty --catalog https://github.com/safl/nosi/releases/latest/download/catalog-latest.toml",
            "#",
            "# Refs are rolling oras :latest tags; the layer digest is verified",
            "# at flash time. The wsl rootfs is intentionally absent (it is",
            "# imported via `wsl --import`, not flashed to a block device).",
            "#",
            "# For content-pinned flashes (same bytes every time), use the",
            "# sibling catalog.toml from the same release: it carries refs",
            "# pinned to the release's ISO-week tag.",
        ]
    else:
        header = [
            "# nosi image catalog, bty-compatible (schema v1). Generated from",
            "# variants.yml by tools/gen_catalog.py and published as a GitHub",
            f"# release asset, pinned to oras tag :{ref_tag}.",
            "#",
            "# Pinned form (this file):",
            f"#   https://github.com/safl/nosi/releases/download/{ref_tag}/catalog.toml",
            "#",
            "# Or always-latest pointer (auto-bumps with each release;",
            "# refs inside are pinned to whatever tag was current at",
            "# fetch time):",
            "#   https://github.com/safl/nosi/releases/latest/download/catalog.toml",
            "#",
            "# Point bty at it:",
            "#",
            f"#   bty --catalog https://github.com/safl/nosi/releases/download/{ref_tag}/catalog.toml",
            "#",
            "# Refs are pinned to a specific build, so an operator running",
            "# the same URL months apart picks up identical bytes (the layer",
            "# digest is still verified at flash time as a tamper check). The",
            "# wsl rootfs is intentionally absent (it is imported via",
            "# `wsl --import`, not flashed to a block device).",
            "#",
            "# For a rolling oras :latest catalog (always whatever ghcr",
            "# currently serves), use catalog-latest.toml from this release.",
        ]
    lines = ["version = 1", "", *header]
    for name in variants:  # insertion order == registry order
        entry = variants[name]
        if not entry.get("flashable"):
            continue
        desc = _load_description(name)  # raises if the file is missing/empty
        arch = str(entry.get("arch", "x86_64")).strip()
        lines += [
            "",
            "[[images]]",
            f'name = "nosi {name} ({arch}, {label})"',
            f'src = "oras://{ORAS_NAMESPACE}/{name}:{ref_tag}"',
            'format = "img.gz"',
            # Emitted as a structured field (not just baked into the
            # human-readable name above) so bty's catalog parser picks
            # it up authoritatively. bty.images.detect_arch_from_name
            # would catch most of these from the variant name as a
            # fallback, but a structured field removes the heuristic
            # round-trip and lets bty show the canonical value
            # (matching ``uname -m``) directly in its Arch column.
            f'arch = "{arch}"',
            f'description = "{_toml_escape(desc)}"',
        ]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--describe", metavar="VARIANT", help="print the variant's description")
    group.add_argument(
        "--describe-wsl", metavar="VARIANT", help="print the variant's wsl_description"
    )
    parser.add_argument(
        "--ref-tag",
        default="latest",
        help=(
            "oras tag baked into each image's src (default: 'latest' for the"
            " rolling catalog; pass the release's dated tag like"
            " '2026.06.16-7cf3895' for a content-pinned catalog)"
        ),
    )
    parser.add_argument(
        "output",
        nargs="?",
        help="catalog.toml output path (default: stdout) when no --describe* flag is given",
    )
    args = parser.parse_args(argv[1:])

    variants = _load_registry()

    if args.describe:
        print(_describe(variants, args.describe, key="description"))
        return 0
    if args.describe_wsl:
        print(_describe(variants, args.describe_wsl, key="wsl_description"))
        return 0

    rendered = _render_catalog(variants, ref_tag=args.ref_tag)
    # Parse-back round-trip so a malformed render fails here, not in a
    # consumer. tomllib is stdlib on 3.11+.
    import tomllib

    tomllib.loads(rendered)
    if args.output:
        Path(args.output).write_text(rendered, encoding="utf-8")
        print(f"wrote {args.output} ({len(rendered)} bytes)", file=sys.stderr)
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
