"""Unit tests for cijoe/scripts/userdata_render.py (marker expansion)."""

from __future__ import annotations

import base64
import gzip
import io
import tarfile

import pytest
import userdata_render


@pytest.fixture
def provision_tree(tmp_path, monkeypatch):
    """A miniature provision/ tree inside a fake repo root, with the
    version pinned via the env override so no git lookup happens."""
    monkeypatch.setenv("NOSI_VERSION", "2026.06.11-test")
    root = tmp_path / "provision"
    (root / "steps").mkdir(parents=True)
    (root / "apply.sh").write_text("#!/bin/sh\necho apply\n")
    (root / "steps" / "01-demo.sh").write_text("#!/bin/sh\necho demo\n")
    return root


def test_version_marker_always_substituted(tmp_path, provision_tree):
    src = tmp_path / "u.user"
    src.write_text("#cloud-config\n# build __NOSI_VERSION__\n")
    out = userdata_render.render(src, provision_tree)
    assert "__NOSI_VERSION__" not in out
    assert "2026.06.11-test" in out


def test_no_marker_passthrough(tmp_path, provision_tree):
    body = "#cloud-config\npackages:\n  - git\n"
    src = tmp_path / "u.user"
    src.write_text(body)
    assert userdata_render.render(src, provision_tree) == body


def test_write_files_marker_expands_scripts(tmp_path, provision_tree):
    src = tmp_path / "u.user"
    src.write_text("#cloud-config\nwrite_files:\n  # __NOSI_PROVISION_FILES__\n")
    out = userdata_render.render(src, provision_tree)
    assert "__NOSI_PROVISION_FILES__" not in out
    assert "/opt/nosi/provision/apply.sh" in out
    assert "/opt/nosi/provision/steps/01-demo.sh" in out
    assert "/opt/nosi/.nosi-version" in out


def test_tarball_marker_is_single_line_and_decodes(tmp_path, provision_tree):
    src = tmp_path / "u.user"
    src.write_text("#cloud-config\nruncmd:\n  - echo '__NOSI_PROVISION_TARBALL__' | b64\n")
    out = userdata_render.render(src, provision_tree)
    assert "__NOSI_PROVISION_TARBALL__" not in out
    payload = next(ln for ln in out.splitlines() if "| b64" in ln)
    b64 = payload.split("'")[1]
    with tarfile.open(fileobj=io.BytesIO(gzip.decompress(base64.b64decode(b64)))) as tar:
        names = tar.getnames()
    assert any("apply.sh" in n for n in names)
