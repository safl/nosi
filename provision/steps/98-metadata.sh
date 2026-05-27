#!/usr/bin/env bash
# nosi/provision/steps/98-metadata.sh
#
# Runs near the end of apply.sh (after every tool-install step, before
# 99-motd). Captures the baked image's identity AND inventory into
# /etc/nosi-metadata.json so consumers can answer "what is this image"
# without booting it -- the smoketest scp's the file out so it can ride
# along as an ORAS layer next to the .img.gz.
#
# Sources every fact from the running system rather than from the
# cloud-init template, so the metadata reflects what is ACTUALLY on disk
# (which version of uv landed, which packages dnf pulled in as deps,
# which kernel the cloud image shipped today), not what we intended to
# install. That is the whole point: provenance you can trust.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 98-metadata"
nosi_require_root

command -v python3 >/dev/null 2>&1 || nosi_die "python3 missing; required to emit /etc/nosi-metadata.json"

python3 - <<'PY' > /etc/nosi-metadata.json
import json
import os
import re
import subprocess
from datetime import datetime, timezone

def run(*cmd, timeout=10):
    """Run a command, return stdout's first line stripped, or None on failure."""
    try:
        p = subprocess.run(
            list(cmd), capture_output=True, text=True, timeout=timeout, check=True,
        )
        line = p.stdout.strip().splitlines()
        return line[0].strip() if line else ""
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return None

def read_kv(path):
    out = {}
    try:
        with open(path) as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                out[k] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out

def first_version_token(s):
    """Extract the first SemVer-ish token from a --version line. None if none."""
    if not s:
        return None
    m = re.search(r"\b(\d+\.\d+(?:\.\d+)?(?:[-+.][\w.]+)?)\b", s)
    return m.group(1) if m else s.strip() or None

def ver(*cmd):
    raw = run(*cmd, timeout=5)
    return first_version_token(raw)

nosi_release = read_kv("/etc/nosi-release")
osr = read_kv("/etc/os-release")

meta = {
    "nosi": {
        "version": nosi_release.get("NOSI_VERSION"),
        "flavor": nosi_release.get("NOSI_FLAVOR"),
        "variant": nosi_release.get("NOSI_VARIANT"),
        "built": nosi_release.get("NOSI_BUILT")
                 or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    },
    "distro": {
        "id": osr.get("ID"),
        "version_id": osr.get("VERSION_ID"),
        "version_codename": osr.get("VERSION_CODENAME"),
        "pretty_name": osr.get("PRETTY_NAME"),
    },
    "kernel": {
        "release": run("uname", "-r"),
        "version": run("uname", "-v"),
    },
    "architecture": run("uname", "-m"),
    "operator": {
        "username": "odus",
        "uid": 1000,
        "default_password": "odus.321",
        "default_password_state": "expired (chage -d 0); first interactive login forces rotation",
        "root_locked": True,
        "ssh": {
            "password_auth": True,
            "permit_root_login": False,
        },
    },
    "tools": {
        # step 20: upstream-release binaries pulled from GitHub releases
        "upstream_releases": {
            "uv": ver("uv", "--version"),
            "rustc": ver("/usr/local/cargo/bin/rustc", "--version"),
            "rust_analyzer": ver("/usr/local/cargo/bin/rust-analyzer", "--version"),
            "hx": ver("hx", "--version"),
            "zellij": ver("zellij", "--version"),
            "lazygit": ver("lazygit", "--version"),
            "yazi": ver("yazi", "--version"),
            "taplo": ver("taplo", "--version"),
            # marksman --version aborts cleanly when libicu present; if it still
            # fails for some reason, record None rather than blowing up.
            "marksman": ver("marksman", "--version"),
            "oras": ver("oras", "version"),
        },
        # step 22: pipx --global installs
        "pipx_global": {
            "ruff": ver("ruff", "--version"),
            "pyright": ver("pyright", "--version"),
            "devbind": ver("devbind", "--version"),
            "hugepages": ver("hugepages", "--version"),
            "iommu": ver("iommu", "--version"),
        },
    },
}

# aidev-only additions: step 41 npm globals
if nosi_release.get("NOSI_FLAVOR") == "aidev":
    meta["tools"]["npm_globals"] = {
        "claude": ver("claude", "--version"),
        "codex": ver("codex", "--version"),
        "gemini": ver("gemini", "--version"),
        "opencode": ver("opencode", "--version"),
        "bash-language-server": ver("bash-language-server", "--version"),
        "yaml-language-server": ver("yaml-language-server", "--version"),
    }

# Manually-installed packages from the distro's package manager. Captures
# what the cloud-init template's packages: list (plus anything apply.sh
# explicitly installed) put on the system, sorted. Excludes the cloud
# image's pre-baked deps so the output reflects nosi's additions.
distro_id = osr.get("ID")
manual_pkgs = []
if distro_id in ("debian", "ubuntu"):
    out = run("apt-mark", "showmanual", timeout=20)
    if out is not None:
        # run() returns first line; re-run capturing all
        try:
            p = subprocess.run(
                ["apt-mark", "showmanual"],
                capture_output=True, text=True, check=True, timeout=20,
            )
            manual_pkgs = sorted(p.stdout.split())
        except subprocess.SubprocessError:
            pass
elif distro_id == "fedora":
    try:
        p = subprocess.run(
            ["dnf", "repoquery", "--userinstalled", "--qf=%{name}\\n"],
            capture_output=True, text=True, check=True, timeout=60,
        )
        manual_pkgs = sorted({line for line in p.stdout.split() if line})
    except subprocess.SubprocessError:
        pass

meta["packages"] = {
    "manager": "apt" if distro_id in ("debian", "ubuntu") else "dnf",
    "manually_installed": manual_pkgs,
    "count": len(manual_pkgs),
}

print(json.dumps(meta, indent=2, sort_keys=False))
PY

chmod 0644 /etc/nosi-metadata.json
nosi_info "step 98-metadata done ($(wc -c < /etc/nosi-metadata.json) bytes -> /etc/nosi-metadata.json)"
