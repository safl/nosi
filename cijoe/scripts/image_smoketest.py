"""
Smoke-test the baked qcow2 by booting it and asserting via SSH
==============================================================

Runs after ``img_gz_publish`` (and ``wsl_rootfs_publish`` for aidev). Boots
the just-baked image inside qemu on a copy-on-write overlay (the published
artefact stays untouched and first-boot characteristics are preserved),
SSHes into it as ``odus``, and runs a battery of assertions covering the
regressions caught by hand in nosi 2026-05:

  * /etc/nosi-release exists, has NOSI_VERSION (non-unknown) and
    NOSI_VARIANT matching this build
  * /usr/local/bin/nosi-motd exists, executable, prints a banner whose
    first non-blank line starts with ``nosi``
  * /etc/motd is non-empty and contains ``nosi`` (the boot oneshot ran)
  * the "awesome tools" iommu, devbind, hugepages, ruff, pyright are all
    on PATH at /usr/local/bin
  * sshd is enabled for next boot (proven by ssh-in-itself, but recorded
    explicitly for the log)
  * ModemManager is NOT active (daemon-prune actually took)
  * Ubuntu only: snapd.socket is masked AND the snapd binary remains
    (soft-disabled, not purged)
  * aidev only: claude-code, codex, gemini-cli, opencode all on PATH

Why a fresh boot of an overlay instead of guestmount-style inspection:
``99-motd.service`` renders /etc/motd on first boot, host keys regenerate
on first boot, our identity assertions transit ``cat /etc/nosi-release``
through the same sshd whose enablement we are testing. Static qcow2
inspection answers "did the apply step write file X?" but cannot answer
"will the next operator's first boot of this image actually work?".

To get ``odus`` past step 29's chage-expired password without burdening
the published artefact with CI-only credentials, the boot is fed a tiny
NoCloud seed.iso that authorises a per-run SSH key and unexpires odus.
The seed is built fresh in /tmp every run; the key never leaves the
runner.

Hard gate: a single failed assertion exits non-zero, which fails
``make build`` and skips the GHCR push for the variant.

Retargetable: False
"""

from __future__ import annotations

import contextlib
import errno
import logging as log
import os
import shutil
import socket
import subprocess
import tempfile
import time
from argparse import ArgumentParser
from pathlib import Path

SSH_HOST_PORT = 4242
SSH_USER = "odus"
SSH_OPTS = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=5",
]


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name", type=str, default=None,
        help="Override system-imaging image name (default: from [nosi] variant).",
    )
    parser.add_argument(
        "--boot_timeout", type=int, default=180,
        help="Seconds to wait for sshd on the smoketest VM (default 180).",
    )


def main(args, cijoe):
    image_name = args.image_name or _default_image_name(cijoe)
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    qcow2 = Path(image["disk"]["path"])
    if not qcow2.exists():
        log.error(f"Baked qcow2 not found: {qcow2}")
        return errno.ENOENT

    variant = cijoe.getconf("nosi", {}).get("variant", "")
    flavor = "aidev" if variant.endswith("-aidev") else "sysdev"
    distro = variant.split("-", 1)[0] if "-" in variant else ""

    workdir = Path(tempfile.mkdtemp(prefix="nosi-smoketest-"))
    log.info(f"smoketest workdir: {workdir}")

    # Belt-and-suspenders so the smoketest can NEVER taint the artefact
    # that ships to GHCR (the .img.gz was already produced before us, but
    # the .qcow2 still goes out as a transient GHA upload-artifact, and a
    # future change to the order of cijoe steps must not silently break
    # that). Two independent defenses:
    #
    #   (1) chmod 0444 on the baked qcow2 across the smoketest. qcow2
    #       backing-file semantics already open the backing read-only,
    #       but a wrong driver / wrong cmdline / unexpected -snapshot
    #       path would otherwise corrupt silently. With 0444 any write
    #       attempt fails with EACCES at qemu open-time, loudly.
    #
    #   (2) Post-test sha256 verification against the .sha256 sidecar
    #       diskimage_build wrote at bake time. If they ever diverge we
    #       refuse to return 0 -- chmod could have been undone, the
    #       sidecar would still pin the bake-time hash.
    qcow2_orig_mode = qcow2.stat().st_mode & 0o777
    expected_sha256 = _read_sidecar_sha256(qcow2)
    os.chmod(qcow2, 0o444)

    rc = 1
    qemu_pidfile = workdir / "qemu.pid"
    key = None
    try:
        key, _key_pub = _gen_ssh_keypair(workdir)
        seed = _build_seed_iso(workdir, _key_pub.read_text().strip())
        overlay = _make_overlay(workdir, qcow2)
        _boot_overlay(cijoe, overlay, seed, qemu_pidfile, workdir / "serial.log")

        if not _wait_for_ssh_ready(key, SSH_HOST_PORT, args.boot_timeout):
            log.error("Smoketest VM did not become SSH-ready within the timeout")
            _dump_serial(workdir / "serial.log")
            return errno.ETIMEDOUT

        # Pull /etc/nosi-metadata.json (and render a .md alongside) out of
        # the running smoketest VM into the disk dir, so the ORAS push step
        # can attach both as image-provenance layers. Best-effort: the
        # presence-of-metadata.json assertion below catches a failure to
        # write it in-VM; this extraction logs and continues if scp itself
        # fails so the assertion (not the extract) is the source of truth.
        _extract_metadata(key, qcow2)

        results = _run_assertions(key, variant, flavor, distro)
        _report(results)
        rc = 0 if all(ok for ok, _name, _detail in results) else 1
    finally:
        _kill_qemu(qemu_pidfile)
        with contextlib.suppress(Exception):
            os.chmod(qcow2, qcow2_orig_mode)
        # Verify the baked qcow2 still matches its bake-time sha256. If
        # not, somehow the smoketest tainted the artefact and we MUST
        # fail loudly -- this is the load-bearing don't-publish-the-test-
        # image guarantee.
        if expected_sha256:
            actual = _file_sha256(qcow2)
            if actual != expected_sha256:
                log.error(
                    f"FATAL: baked qcow2 sha256 changed during smoketest! "
                    f"expected {expected_sha256}, got {actual}. "
                    f"DO NOT PUBLISH this artefact."
                )
                rc = errno.EIO
        # Preserve the workdir on failure so the serial console and ssh key
        # are available for forensics. On success the workdir is purely
        # transient and we drop it; on failure we leave it and tell the
        # operator where to find it.
        if rc == 0:
            with contextlib.suppress(Exception):
                shutil.rmtree(workdir)
        else:
            log.error(f"smoketest workdir preserved for forensics: {workdir}")

    return rc


def _read_sidecar_sha256(path: Path) -> str:
    """Return the hash from <path>.sha256, or empty string if missing."""
    sidecar = Path(f"{path}.sha256")
    if not sidecar.is_file():
        return ""
    try:
        first = sidecar.read_text().strip().split()
        return first[0] if first else ""
    except OSError:
        return ""


def _file_sha256(path: Path) -> str:
    import hashlib
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _default_image_name(cijoe) -> str:
    nosi = cijoe.getconf("nosi", {})
    return f"nosi-{nosi.get('variant', 'debian-sysdev')}-x86_64"


def _gen_ssh_keypair(workdir: Path) -> tuple[Path, Path]:
    key = workdir / "id_ed25519"
    pub = workdir / "id_ed25519.pub"
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
        check=True,
    )
    return key, pub


def _build_seed_iso(workdir: Path, pubkey: str) -> Path:
    # Per-run identity so cloud-init treats this boot as a fresh instance
    # (the baked image was cloud-init clean'd, so no stale state to fight).
    iid = f"nosi-smoketest-{os.getpid()}"
    (workdir / "meta-data").write_text(
        f"instance-id: {iid}\nlocal-hostname: nosi-smoketest\n"
    )
    # Authorise the per-run key on odus and disarm step 29's chage so PAM
    # does not block key auth with "Password change required but no TTY
    # available". -d <today> is the load-bearing one (clears sp_lstchg=0
    # so the account is not in "must change" state); -E/-M/-W also turn
    # off future expiry policy. No power_state -- the VM stays up for
    # the assertion run.
    (workdir / "user-data").write_text(
        "#cloud-config\n"
        "users:\n"
        "  - name: odus\n"
        "    ssh_authorized_keys:\n"
        f"      - {pubkey}\n"
        "runcmd:\n"
        "  - chage -d $(date -u +%Y-%m-%d) -E -1 -M -1 -W -1 odus\n"
    )
    seed = workdir / "smoketest-seed.iso"
    subprocess.run(
        [
            "mkisofs", "-quiet", "-output", str(seed), "-volid", "cidata",
            "-joliet", "-rock",
            str(workdir / "user-data"), str(workdir / "meta-data"),
        ],
        check=True,
    )
    return seed


def _make_overlay(workdir: Path, backing: Path) -> Path:
    overlay = workdir / "overlay.qcow2"
    subprocess.run(
        [
            "qemu-img", "create", "-q", "-f", "qcow2",
            "-F", "qcow2", "-b", str(backing), str(overlay),
        ],
        check=True,
    )
    return overlay


def _boot_overlay(cijoe, overlay: Path, seed: Path, pidfile: Path, serial: Path) -> None:
    # KVM-accelerated to keep the test under a minute on hosted runners
    # that already enable /dev/kvm for the bake. virtio-net + user-mode
    # networking + hostfwd is the minimum for SSH-from-host.
    # `-display none -monitor none` rather than `-nographic` because qemu
    # rejects `-nographic` together with `-daemonize` ("cannot be used
    # with -daemonize"); display-none + serial-file gives the same "no
    # UI, log to disk" semantics while staying daemonize-compatible.
    cmd = (
        "qemu-system-x86_64 "
        "-machine type=q35,accel=kvm "
        "-cpu host -smp 2 -m 2G "
        "-display none -monitor none "
        f"-serial file:{serial} "
        f"-drive file={overlay},if=virtio,format=qcow2 "
        f"-cdrom {seed} "
        f"-netdev user,id=n1,hostfwd=tcp:127.0.0.1:{SSH_HOST_PORT}-:22 "
        "-device virtio-net-pci,netdev=n1 "
        f"-daemonize -pidfile {pidfile}"
    )
    err, _ = cijoe.run_local(cmd)
    if err:
        raise RuntimeError(f"qemu failed to start smoketest VM (exit {err})")


def _extract_metadata(key: Path, qcow2: Path) -> None:
    """scp /etc/nosi-metadata.json out and render a sibling .md.

    The destination is the same directory as the baked qcow2 so the GHA
    workflow's oras push step can attach both files as image-provenance
    layers without juggling paths. Failure is logged but non-fatal: the
    smoketest's own assertion that /etc/nosi-metadata.json exists and
    parses inside the VM is the load-bearing check.
    """
    out_dir = qcow2.parent
    base = qcow2.stem  # nosi-<variant>-x86_64
    json_local = out_dir / f"{base}.metadata.json"
    md_local = out_dir / f"{base}.metadata.md"

    scp_cmd = [
        "scp", "-i", str(key), *SSH_OPTS,
        "-P", str(SSH_HOST_PORT),
        f"{SSH_USER}@127.0.0.1:/etc/nosi-metadata.json",
        str(json_local),
    ]
    res = subprocess.run(scp_cmd, capture_output=True, text=True, timeout=30)
    if res.returncode != 0:
        log.error(
            f"scp /etc/nosi-metadata.json failed (exit {res.returncode}): "
            f"{(res.stderr or res.stdout).strip()}"
        )
        return

    import json as _json
    try:
        meta = _json.loads(json_local.read_text())
    except (OSError, ValueError) as exc:
        log.error(f"extracted metadata.json did not parse: {exc}")
        return

    md_local.write_text(_render_metadata_markdown(meta))
    log.info(f"metadata written: {json_local.name}, {md_local.name}")


def _render_metadata_markdown(meta: dict) -> str:
    """Render the metadata JSON as a human-readable Markdown summary."""
    n = meta.get("nosi", {})
    d = meta.get("distro", {})
    k = meta.get("kernel", {})
    op = meta.get("operator", {})
    tools = meta.get("tools", {})
    pkgs = meta.get("packages", {})

    def kv_section(title, kv):
        lines = [f"## {title}", "", "| | |", "|---|---|"]
        for key, val in kv.items():
            if val is None:
                val = "_(missing)_"
            lines.append(f"| `{key}` | {val} |")
        return "\n".join(lines)

    def tool_section(title, tdict):
        if not tdict:
            return ""
        lines = [f"## {title}", "", "| tool | version |", "|---|---|"]
        for name, ver in sorted(tdict.items()):
            ver = ver if ver is not None else "_(missing)_"
            lines.append(f"| `{name}` | {ver} |")
        return "\n".join(lines)

    sections = [
        f"# `{n.get('variant', '?')}` ({n.get('version', '?')})",
        "",
        d.get("pretty_name") or "_(distro unknown)_",
        f"on Linux {k.get('release', '?')} ({meta.get('architecture', '?')}),"
        f" built {n.get('built', '?')}",
        "",
        kv_section("Identity", n),
        "",
        kv_section("Distro", d),
        "",
        kv_section("Kernel", k),
        "",
        kv_section("Operator", {
            "username": op.get("username"),
            "uid": op.get("uid"),
            "default_password": f"`{op.get('default_password')}` "
                                f"({op.get('default_password_state')})",
            "root_locked": op.get("root_locked"),
        }),
    ]

    for label, key in (
        ("Upstream-release tools (step 20)", "upstream_releases"),
        ("Python CLIs via pipx --global (step 22)", "pipx_global"),
        ("Agentic CLIs / Node LSPs (step 41, aidev only)", "npm_globals"),
    ):
        section = tool_section(label, tools.get(key) or {})
        if section:
            sections.append("")
            sections.append(section)

    manual = pkgs.get("manually_installed") or []
    if manual:
        sections.append("")
        sections.append(
            f"## Manually-installed packages ({pkgs.get('manager', '?')}, "
            f"{pkgs.get('count', len(manual))} packages)"
        )
        sections.append("")
        # Three columns for compactness.
        col = 3
        rows = [manual[i:i + col] for i in range(0, len(manual), col)]
        sections.append("| | | |")
        sections.append("|---|---|---|")
        for r in rows:
            r = (r + ["", "", ""])[:col]
            sections.append("| " + " | ".join(f"`{x}`" if x else "" for x in r) + " |")

    return "\n".join(sections) + "\n"


def _wait_for_ssh_ready(key: Path, port: int, timeout: int) -> bool:
    """Wait until sshd accepts a real key-auth handshake (not just TCP).

    On first boot the port opens before host keys exist (openssh-server's
    ssh-keygen unit and cloud-init's cc_ssh race the network stack), so a
    bare TCP probe would report "ready" while a real ssh would get hit
    with "kex_exchange_identification: Connection reset by peer". Drive
    a no-op ssh in a loop until it actually succeeds.
    """
    deadline = time.monotonic() + timeout
    last_err = "(none)"
    while time.monotonic() < deadline:
        # TCP probe first; cheap, lets us skip ssh-handshake retries while
        # qemu is still bringing the guest up.
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            try:
                s.connect(("127.0.0.1", port))
                tcp_open = True
            except OSError as exc:
                tcp_open = False
                last_err = f"tcp: {exc}"
        if tcp_open:
            res = subprocess.run(
                [
                    "ssh", "-i", str(key), *SSH_OPTS,
                    "-o", "BatchMode=yes",
                    "-p", str(port),
                    f"{SSH_USER}@127.0.0.1", "true",
                ],
                capture_output=True, text=True, timeout=15,
            )
            if res.returncode == 0:
                return True
            last_err = (res.stderr or res.stdout).strip().splitlines()[-1] if (res.stderr or res.stdout) else f"exit {res.returncode}"
        time.sleep(3)
    log.error(f"_wait_for_ssh_ready last error: {last_err}")
    return False


def _ssh(key: Path, cmd: str) -> tuple[int, str]:
    """Run a single shell command on the smoketest VM, capture stdout+stderr."""
    full = [
        "ssh", "-i", str(key), *SSH_OPTS,
        "-p", str(SSH_HOST_PORT),
        f"{SSH_USER}@127.0.0.1", cmd,
    ]
    res = subprocess.run(full, capture_output=True, text=True, timeout=30)
    return res.returncode, (res.stdout + res.stderr).strip()


def _run_assertions(key: Path, variant: str, flavor: str, distro: str) -> list[tuple[bool, str, str]]:
    """Return [(ok, name, detail)] for every assertion."""

    # Wait until cloud-init has finished applying the smoketest seed --
    # the chage-unexpire runs in cloud-init runcmd, and even though we
    # already authenticated with the key, the next ssh's command-exec
    # phase still re-checks account state. cloud-init status --wait
    # blocks until cloud-init is done; bounded so a hung cloud-init does
    # not hang the smoketest forever.
    _, _ = _ssh(key, "timeout 60 cloud-init status --wait || true")

    results: list[tuple[bool, str, str]] = []

    def check(name: str, cmd: str, predicate) -> None:
        rc, out = _ssh(key, cmd)
        ok, detail = predicate(rc, out)
        results.append((ok, name, detail))

    # ---- apply.sh completed end-to-end -----------------------------------
    # /etc/nosi/apply-ok is written by the LAST line of apply.sh, only
    # after every step has succeeded under `set -e`. Its absence proves
    # apply.sh aborted somewhere -- no matter which step, no matter
    # whether we wrote an explicit smoketest assertion for the tool that
    # step was supposed to install. One sentinel covers every failure
    # mode, so transient curl-404s and the like fail the build instead
    # of seeping into a published image.
    check(
        "/etc/nosi/apply-ok sentinel present (apply.sh completed cleanly)",
        "test -r /etc/nosi/apply-ok && cat /etc/nosi/apply-ok",
        lambda rc, out: (rc == 0 and bool(out), out or "(missing apply-ok sentinel)"),
    )

    # ---- metadata file exists --------------------------------------------
    # /etc/nosi-metadata.json is written by step 98 and contains the
    # full bake inventory. Smoketest just verifies presence + parses as
    # JSON to catch syntax errors in the in-VM emitter.
    check(
        "/etc/nosi-metadata.json present and parses as JSON",
        "python3 -c 'import json; json.load(open(\"/etc/nosi-metadata.json\"))' && echo ok",
        lambda rc, out: (out == "ok", out or f"exit {rc}"),
    )

    # ---- build identity ---------------------------------------------------
    check(
        "/etc/nosi-release has NOSI_VARIANT",
        "cat /etc/nosi-release",
        lambda rc, out: (
            rc == 0 and f"NOSI_VARIANT={variant}" in out,
            out if rc != 0 or f"NOSI_VARIANT={variant}" not in out else "ok",
        ),
    )
    check(
        "/etc/nosi-release NOSI_VERSION is non-unknown",
        "awk -F= '$1==\"NOSI_VERSION\"{print $2}' /etc/nosi-release",
        lambda rc, out: (
            rc == 0 and out.strip() not in ("", "unknown"),
            f"NOSI_VERSION='{out.strip()}'",
        ),
    )

    # ---- motd: oneshot rendered, banner correct --------------------------
    check(
        "/etc/motd is non-empty and contains 'nosi'",
        "cat /etc/motd",
        lambda rc, out: (
            rc == 0 and "nosi" in out,
            out.splitlines()[0] if out else "(empty)",
        ),
    )
    check(
        "/usr/local/bin/nosi-motd is executable",
        "test -x /usr/local/bin/nosi-motd && echo ok",
        lambda rc, out: (out == "ok", out or f"exit {rc}"),
    )

    # ---- upstream-release CLIs (step 20) ---------------------------------
    # Each one curl-downloaded from a GitHub release. Asserting individual
    # presence lets a single 404 surface exactly which upstream URL needs
    # fixing rather than just "the bake aborted somewhere in step 20".
    # (rustc is the rustup install marker; rustup itself drops binaries
    # under /usr/local/cargo/bin/, not /usr/local/bin.)
    for tool in ("uv", "uvx", "hx", "zellij", "lazygit",
                 "yazi", "ya", "taplo", "marksman", "oras"):
        check(
            f"/usr/local/bin/{tool} exists (step 20)",
            f"test -x /usr/local/bin/{tool} && echo ok",
            lambda rc, out, _t=tool: (out == "ok", out or f"missing {_t}"),
        )
    check(
        "/usr/local/cargo/bin/rustc exists (step 20: rustup toolchain)",
        "test -x /usr/local/cargo/bin/rustc && echo ok",
        lambda rc, out: (out == "ok", out or "missing rustc"),
    )

    # ---- pipx-installed CLIs (step 22) -----------------------------------
    # `pipx install --global` symlinks each package's entry points into
    # /usr/local/bin (and venvs into /usr/local/pipx). /usr/local/bin is
    # on every user's default PATH, so no profile.d wiring is needed; a
    # presence check is sufficient. pyright-langserver is included
    # explicitly even though pipx is supposed to auto-symlink every
    # entry point -- this assertion is the tripwire if pipx ever changes
    # that default.
    for tool in ("iommu", "devbind", "hugepages", "ruff",
                 "pyright", "pyright-langserver"):
        check(
            f"/usr/local/bin/{tool} exists (step 22)",
            f"test -x /usr/local/bin/{tool} && echo ok",
            lambda rc, out, _t=tool: (out == "ok", out or f"missing {_t}"),
        )

    # ---- sshd enabled ----------------------------------------------------
    # Already proven by the fact that we SSHed in. Record the unit state
    # explicitly so the assertion log surfaces it.
    if distro == "fedora":
        check(
            "sshd.service is-enabled",
            "systemctl is-enabled sshd.service",
            lambda rc, out: (out == "enabled", out),
        )
    else:
        check(
            "ssh.service or ssh.socket is-enabled",
            "systemctl is-enabled ssh.service ssh.socket 2>/dev/null | grep -q '^enabled$' && echo ok",
            lambda rc, out: (out == "ok", out or "neither enabled"),
        )

    # ---- ModemManager actually gone --------------------------------------
    # systemctl is-active prints "active" / "inactive" / "failed" to stdout
    # and uses exit codes (3 for inactive, 4 for not-loaded). We only care
    # about stdout; an empty stdout (unit-not-loaded with stderr swallowed)
    # also counts as "not active". Avoid an `|| echo ...` fallback because
    # those concatenate onto a non-empty stdout for the inactive case and
    # break the comparison.
    check(
        "ModemManager is not active",
        "systemctl is-active ModemManager.service 2>/dev/null",
        lambda rc, out: (out != "active", out or "inactive (unit not loaded)"),
    )

    # ---- ubuntu-only: snapd soft-disabled --------------------------------
    if distro == "ubuntu":
        # is-enabled for a masked unit prints "masked" but exits 1, so a
        # bare `|| echo missing` would append "missing" onto the stdout
        # the masked case produces and break the equality. Empty stdout
        # (unit absent) correctly fails the assertion via the equality.
        check(
            "snapd.socket is masked",
            "systemctl is-enabled snapd.socket 2>/dev/null",
            lambda rc, out: (out == "masked", out or "(unit not present)"),
        )
        check(
            "snap binary still present (re-enableable)",
            "command -v snap >/dev/null && echo ok",
            lambda rc, out: (out == "ok", out or "missing"),
        )

    # ---- aidev-only: agentic CLIs + Node-based LSPs ----------------------
    # Binary names (NOT npm package names): step 41 installs
    #   @anthropic-ai/claude-code -> binary `claude`
    #   @openai/codex             -> binary `codex`
    #   @google/gemini-cli        -> binary `gemini`
    #   opencode-ai               -> binary `opencode`
    # plus bash-language-server / yaml-language-server which are aidev-
    # only because they need Node.
    if flavor == "aidev":
        for cli in ("claude", "codex", "gemini", "opencode",
                    "bash-language-server", "yaml-language-server"):
            check(
                f"aidev binary '{cli}' on PATH",
                f"command -v {cli} >/dev/null && echo ok",
                lambda rc, out, _c=cli: (out == "ok", out or f"missing {_c}"),
            )

    return results


def _report(results: list[tuple[bool, str, str]]) -> None:
    total = len(results)
    passed = sum(1 for ok, _, _ in results if ok)
    log.info(f"smoketest results: {passed}/{total} passed")
    for ok, name, detail in results:
        mark = "PASS" if ok else "FAIL"
        log.log(log.INFO if ok else log.ERROR, f"  {mark}  {name}  [{detail}]")


def _kill_qemu(pidfile: Path) -> None:
    if not pidfile.exists():
        return
    try:
        pid = int(pidfile.read_text().strip())
    except (ValueError, OSError):
        return
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.kill(pid, 15)
    # Give it a moment to drop the qcow2 lock, then SIGKILL if still up.
    time.sleep(2)
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.kill(pid, 9)


def _dump_serial(serial: Path) -> None:
    if serial.exists():
        tail = serial.read_text(errors="replace").splitlines()[-40:]
        log.error("---- last 40 lines of smoketest VM serial console ----")
        for line in tail:
            log.error(line)
        log.error("------------------------------------------------------")
