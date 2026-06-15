"""Unit tests for the docs catalog renderer (nosi_docs.catalog)."""

from __future__ import annotations

import yaml

from nosi_docs import catalog


def test_known_variants_matches_registry(repo_root):
    data = yaml.safe_load((repo_root / "variants.yml").read_text())["variants"]
    got = catalog.known_variants(repo_root)
    # Every variant is listed, docker included, so the catalog covers every
    # offering. Each tuple is (name, ref, shape).
    assert [name for name, _ref, _shape in got] == list(data.keys())
    for name, ref, shape in got:
        assert ref == f"{catalog.GHCR_PREFIX}/{name}:latest"
        assert shape == (data[name].get("shape") or "?")
    # Regression guard: the docker shape must be present (it used to be filtered
    # out, which left the OCI offering missing from the catalog).
    assert any(shape == "docker" for _n, _r, shape in got)


def test_render_docker_variant_page():
    snap = catalog.VariantSnapshot(
        name="ubuntu-2604-docker",
        ref="ghcr.io/safl/nosi/ubuntu-2604-docker:latest",
        shape="docker",
        description="An OCI image for CI.",
    )
    out = catalog._render_variant_page(snap)
    assert "# `ubuntu-2604-docker`" in out
    assert "An OCI image for CI." in out
    # docker pull flow, not the oras-pull + dd flash the disk images render.
    assert "docker pull ghcr.io/safl/nosi/ubuntu-2604-docker:latest" in out
    assert "oras pull" not in out


def test_render_index_docker_row():
    snap = catalog.VariantSnapshot(
        name="ubuntu-2604-docker", ref="ghcr.io/x", shape="docker", description="x"
    )
    out = catalog._render_index([snap])
    assert "| docker " in out
    assert "ubuntu-2604-docker/index" in out


def test_render_unpublished_variant_page():
    snap = catalog.VariantSnapshot(name="x-1-headless", ref="ghcr.io/x", error="boom")
    out = catalog._render_variant_page(snap)
    assert out.startswith("---\nhide-toc: true\n---")
    assert "# `x-1-headless`" in out
    assert "Not yet published" in out
    assert "boom" in out


def test_render_index_lists_variant_in_toctree():
    snap = catalog.VariantSnapshot(name="x-1-headless", ref="ghcr.io/x", error="boom")
    out = catalog._render_index([snap])
    assert out.startswith("---\nhide-toc: true\n---")
    assert "```{toctree}" in out
    assert "x-1-headless/index" in out
