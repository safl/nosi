#!/usr/bin/env python3
"""Generate a bty-compatible ``catalog.toml`` from ``variants.yml``.

Two jobs, one source of truth (``variants.yml`` at the repo root):

1. ``--describe <variant>`` / ``--describe-wsl <variant>`` -- print one
   variant's use-case prose. ``.github/workflows/build.yml`` calls these
   in its ORAS push steps so the ``org.opencontainers.image.description``
   annotation comes from the registry rather than an inline bash case.

2. no flag (optional output path) -- emit a ``catalog.toml`` listing
   every ``flashable: true`` variant as an ``oras://`` rolling-tag entry.
   Published as a GitHub release asset; operators point bty at it:

       bty --catalog https://github.com/safl/nosi/releases/latest/download/catalog.toml

The catalog is schema v1 (``bty.catalog``). Refs are rolling ``:latest``
tags -- not pre-resolved to digests -- so an operator running the same
URL months apart picks up whatever nosi rebuilt since, with the layer
digest verified at flash time. The wsl rootfs is deliberately excluded
(``flashable: false``): it is imported via ``wsl --import``, not flashed
to a block device, so it has no place in a flashable catalog.

Unknown / mis-registered variants fail loud (non-zero exit, message on
stderr) rather than emitting a placeholder -- a baked-but-unregistered
variant should break the push, not ship a generic description.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
REGISTRY_PATH = REPO_ROOT / "variants.yml"

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


def _describe(variants: dict[str, dict], name: str, *, key: str) -> str:
    entry = _variant(variants, name)
    value = entry.get(key)
    if not value:
        raise SystemExit(f"variant {name!r}: no {key!r} in {REGISTRY_PATH}")
    return str(value).strip()


def _toml_escape(text: str) -> str:
    """Escape a string for a TOML basic (double-quoted) value."""
    return text.replace("\\", "\\\\").replace('"', '\\"')


def _render_catalog(variants: dict[str, dict]) -> str:
    lines = [
        "version = 1",
        "",
        "# nosi image catalog -- bty-compatible (schema v1). Generated from",
        "# variants.yml by tools/gen_catalog.py and published as a GitHub",
        "# release asset:",
        "#",
        "#   https://github.com/safl/nosi/releases/latest/download/catalog.toml",
        "#",
        "# Point bty at it:",
        "#",
        "#   bty --catalog https://github.com/safl/nosi/releases/latest/download/catalog.toml",
        "#",
        "# Refs are rolling oras :latest tags; the layer digest is verified",
        "# at flash time. The wsl rootfs is intentionally absent -- it is",
        "# imported via `wsl --import`, not flashed to a block device.",
    ]
    for name in variants:  # insertion order == registry order
        entry = variants[name]
        if not entry.get("flashable"):
            continue
        desc = str(entry.get("description", "")).strip()
        if not desc:
            raise SystemExit(f"variant {name!r}: flashable but has no description")
        lines += [
            "",
            "[[images]]",
            f'name = "nosi {name} (x86_64, rolling)"',
            f'src = "oras://{ORAS_NAMESPACE}/{name}:latest"',
            'format = "img.gz"',
            f'description = "{_toml_escape(desc)}"',
        ]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--describe", metavar="VARIANT", help="print the variant's description"
    )
    group.add_argument(
        "--describe-wsl", metavar="VARIANT", help="print the variant's wsl_description"
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

    rendered = _render_catalog(variants)
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
