"""Unit tests for the docs catalog renderer (nosi_docs.catalog)."""

from __future__ import annotations

import yaml

from nosi_docs import catalog


def test_known_variants_matches_registry(repo_root):
    data = yaml.safe_load((repo_root / "variants.yml").read_text())["variants"]
    expected = [n for n, s in data.items() if s.get("shape") != "docker"]
    got = catalog.known_variants(repo_root)
    assert [name for name, _ in got] == expected
    for name, ref in got:
        assert ref == f"{catalog.GHCR_PREFIX}/{name}:latest"


def test_render_unpublished_placeholder():
    snap = catalog.VariantSnapshot(name="x-1-headless", ref="ghcr.io/x", error="boom")
    out = catalog._render([snap])
    assert "not yet published" in out
    assert "boom" in out
