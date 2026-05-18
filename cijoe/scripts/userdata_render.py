"""
Render a nosi cloud-init user-data file with provision/ scripts inlined
======================================================================

The cloud-init templates under ``nosi-media/auxiliary/`` can contain a
single marker line, anywhere inside a YAML ``write_files:`` list:

    write_files:
      # __NOSI_PROVISION_FILES__
      ... other entries ...

This script replaces that marker with one ``write_files:`` entry per
file under ``provision/`` (apply.sh, lib/*.sh, steps/*.sh), pointing each
target at ``/opt/nosi/provision/<relative path>`` and chmod 0755. The
output is written next to the source as ``<name>.rendered.user`` (or to
an explicit ``--out`` path).

The bake (``diskimage_build.py``) calls into ``render()`` directly so
templates pass through this step before the NoCloud seed iso is built.
Templates with no marker are copied verbatim, so existing flavors keep
working until their inline blocks get migrated.

Retargetable: False
"""

from __future__ import annotations

import logging as log
from argparse import ArgumentParser
from pathlib import Path

MARKER = "__NOSI_PROVISION_FILES__"


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--src", type=Path, required=True,
        help="Path to the cloud-init template (e.g. nosi-media/auxiliary/cloudinit-sysdev-debian.user)",
    )
    parser.add_argument(
        "--out", type=Path, default=None,
        help="Output path. Defaults to <src>.rendered.user next to the source.",
    )
    parser.add_argument(
        "--provision-root", type=Path, default=None,
        help="Path to the provision/ tree. Defaults to <repo-root>/provision.",
    )


def render(src: Path, provision_root: Path) -> str:
    """Return the user-data text with the marker expanded.

    If the marker is absent the source is returned unchanged so legacy
    templates keep working during the migration.
    """
    template = src.read_text()

    # The marker is expected to appear as a standalone comment line
    # inside a `write_files:` list, e.g. `  # __NOSI_PROVISION_FILES__`.
    # Surrounding prose can mention the marker by name without triggering
    # substitution, as long as the line carries more than just the
    # comment marker. We match lines where the stripped content is
    # exactly `# <MARKER>`.
    expected = f"# {MARKER}"
    marker_line = next(
        (line for line in template.splitlines() if line.strip() == expected),
        None,
    )
    if marker_line is None:
        return template
    indent = marker_line[: len(marker_line) - len(marker_line.lstrip())]

    files = sorted(
        p for p in provision_root.rglob("*")
        if p.is_file() and (p.suffix == ".sh" or p.name == "apply.sh")
    )
    if not files:
        log.warning("no scripts found under %s; marker will be removed", provision_root)

    blocks = []
    for fp in files:
        rel = fp.relative_to(provision_root.parent)  # e.g. "provision/apply.sh"
        target = f"/opt/nosi/{rel.as_posix()}"
        body = fp.read_text()
        # cloud-init's `content: |` block requires every body line to be
        # indented one level deeper than the `content:` key. Two spaces
        # over the entry indent (which is the marker's indent).
        body_indent = indent + "    "
        # Drop the trailing newline (the `|` preserves trailing newlines
        # only if the body ends with one and we re-add it below); strip
        # any line-final whitespace to keep YAML happy.
        body_lines = "\n".join(body_indent + line if line else body_indent.rstrip()
                               for line in body.splitlines())
        blocks.append(
            f"{indent}- path: {target}\n"
            f"{indent}  permissions: '0755'\n"
            f"{indent}  content: |\n"
            f"{body_lines}"
        )

    rendered = "\n\n".join(blocks)
    return template.replace(marker_line, rendered)


def main(args, cijoe):
    src: Path = args.src.resolve()
    if not src.is_file():
        log.error("source not found: %s", src)
        return 2

    provision_root: Path = (
        args.provision_root.resolve() if args.provision_root
        else (src.parents[2] / "provision").resolve()
    )
    if not provision_root.is_dir():
        log.error("provision root not found: %s", provision_root)
        return 2

    out: Path = args.out.resolve() if args.out else src.with_suffix(".rendered.user")
    out.write_text(render(src, provision_root))
    log.info("rendered %s -> %s", src, out)
    return 0
