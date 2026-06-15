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


def test_every_variant_has_a_description_file(registry):
    """Each variant's use-case prose lives in its own descriptions/<name>.md
    (and <name>.wsl.md for the wsl shape). A registered variant without its
    file would fail the ORAS --describe push, so catch it here instead."""
    for name, spec in registry.items():
        assert (gen_catalog.DESCRIPTIONS_DIR / f"{name}.md").is_file(), (
            f"{name}: missing descriptions/{name}.md"
        )
        assert gen_catalog._load_description(name), f"{name}: empty description file"
        if spec["shape"] == "wsl":
            assert (gen_catalog.DESCRIPTIONS_DIR / f"{name}.wsl.md").is_file(), (
                f"{name}: wsl shape needs descriptions/{name}.wsl.md"
            )
            assert gen_catalog._load_description(name, wsl=True), (
                f"{name}: empty wsl description file"
            )


def test_no_orphan_description_files(registry):
    """Every descriptions/*.md maps to a registered variant, so a renamed or
    removed variant does not leave dead prose behind."""
    for path in gen_catalog.DESCRIPTIONS_DIR.glob("*.md"):
        name = path.name[: -len(".wsl.md")] if path.name.endswith(".wsl.md") else path.stem
        assert name in registry, f"{path.name}: no such variant in variants.yml"


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
        # The unique per-image marker is the oras src `.../<name>:latest`,
        # not a bare name substring and not `[images.<name>]` (the renderer
        # emits `[[images]]` table-arrays, so that bracket form never appears
        # and asserting its absence proved nothing).
        ref = f"/{name}:latest"
        if spec["flashable"]:
            assert ref in out, f"flashable {name} missing from catalog.toml"
        else:
            assert ref not in out, f"non-flashable {name} leaked into catalog.toml"


def test_catalog_parses_and_every_image_is_complete(registry):
    """Parse the rendered TOML and assert each image carries the four fields
    bty needs, so a renderer regression fails here, not in bty."""
    import tomllib

    doc = tomllib.loads(gen_catalog._render_catalog(registry))
    assert doc.get("version") == 1
    flashable = [n for n, s in registry.items() if s["flashable"]]
    assert len(doc.get("images", [])) == len(flashable)
    for img in doc["images"]:
        for field in ("name", "src", "format", "arch", "description"):
            assert img.get(field), f"{img.get('name', '?')}: missing {field}"
        assert img["src"].startswith("oras://")
        assert img["description"].strip()


def test_arch_field_matches_registry(registry):
    """Each emitted entry's ``arch`` field equals what variants.yml
    declares (or ``x86_64`` when the variant omits the key). Catches
    a renderer drift where ``arch`` is hard-coded or lost."""
    import tomllib

    doc = tomllib.loads(gen_catalog._render_catalog(registry))
    by_variant = {
        img["src"].rsplit("/", 1)[1].split(":", 1)[0]: img["arch"] for img in doc["images"]
    }
    for name, spec in registry.items():
        if not spec.get("flashable"):
            continue
        expected = str(spec.get("arch", "x86_64"))
        assert by_variant[name] == expected, (
            f"{name}: catalog arch {by_variant[name]!r} != registry {expected!r}"
        )
