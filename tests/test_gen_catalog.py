"""Unit tests for tools/gen_catalog.py + variants.yml schema sanity."""

from __future__ import annotations

import gen_catalog
import pytest

KNOWN_SHAPES = {"headless", "desktop", "wsl", "docker", "lxc", "proxmox"}


@pytest.fixture(scope="module")
def registry():
    return gen_catalog._load_registry()


def test_registry_schema(registry):
    """Guard the variant registry itself: a malformed entry should fail
    here in seconds, not after a 50-minute bake."""
    assert registry, "variants.yml has no variants"
    for name, spec in registry.items():
        assert spec.get("shape") in KNOWN_SHAPES, f"{name}: bad shape {spec.get('shape')!r}"
        assert isinstance(spec.get("flashable"), bool), f"{name}: flashable must be a bool"
        assert str(spec.get("description", "")).strip(), f"{name}: missing description"
        if spec["shape"] == "wsl":
            assert str(spec.get("wsl_description", "")).strip(), (
                f"{name}: wsl needs wsl_description"
            )


def test_variant_names_match_their_shape_suffix(registry):
    for name, spec in registry.items():
        assert name.endswith(f"-{spec['shape']}"), f"{name}: name does not end in -{spec['shape']}"


def test_describe_happy_path(registry):
    text = gen_catalog._describe(registry, "debian-13-headless", key="description")
    assert "Debian 13" in text


def test_describe_unknown_variant_fails_loudly(registry):
    with pytest.raises(SystemExit):
        gen_catalog._describe(registry, "no-such-variant", key="description")


def test_catalog_lists_only_flashable(registry):
    out = gen_catalog._render_catalog(registry)
    for name, spec in registry.items():
        if spec["flashable"]:
            assert name in out, f"flashable {name} missing from catalog.toml"
        else:
            assert f"[images.{name}]" not in out, f"non-flashable {name} leaked into catalog.toml"
