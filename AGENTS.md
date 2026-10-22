# AGENTS.md

nosi bakes system images: headless and desktop disk images for bare metal and
VMs, plus WSL, OCI and LXC rootfs. Upstream cloud images are booted in QEMU,
cloud-init runs `provision/apply.sh`, and the result is smoketested, packed
and pushed to GHCR. User-facing documentation is the Sphinx site under `docs/`
(published at <https://safl.dk/nosi>).

## Layout

```
variants.yml              variant registry: shape, flashable, arch, netboot, paused
descriptions/<name>.md    per-variant prose for the catalog and ORAS annotation
nosi-media/auxiliary/     cloud-init user-data per base (*.user), rpios package list
provision/apply.sh        apply.sh <variant> [--shape-only]; runs steps/ in order
provision/lib/common.sh   distro detection, nosi_pkg_install, nosi_write_if_changed, ...
provision/steps/NN-*.sh   one idempotent step each; BASE, SHAPE and FINAL groups
provision/addons/         no-reboot optional installers behind `nosi-addon`
provision/netboot/        dracut modules for nbdboot
cijoe/configs/<base>.toml per-base build config, including its [[...derive]] shapes
cijoe/tasks/              build.yaml (QEMU bake) and build-rpi.yaml (chroot bake)
cijoe/scripts/            the pipeline steps; image_smoketest.py is the contract
tools/gen_catalog.py      catalog.toml and image descriptions from variants.yml
tests/                    pytest units for the Python helpers
.github/workflows/        lint.yml, build.yml (bake + publish), docs.yml
```

## Build model

Only headless bases are baked. Desktop, WSL, docker, LXC and Proxmox are
derived: `derive_pack` copies the baked base qcow2, chroots in and runs
`apply.sh <derived-variant> --shape-only`, which skips BASE steps. A step
therefore must be idempotent, must self-gate on `NOSI_SHAPE` or
`NOSI_DISTRO` where it does not apply, and must not assume it runs on the
target's kernel when it is a SHAPE step. Write files through
`nosi_write_if_changed` and install packages through `nosi_pkg_install`.
`apply.sh` is fail-fast; `99-motd.sh` running is the proof every step did.

Adding a variant touches `variants.yml`, `descriptions/`, the matrix in
`.github/workflows/build.yml` and, for a base, `cijoe/configs/` and
`nosi-media/auxiliary/`. The matrix and the registry must stay in sync; the
publish step fails loudly when they do not.

Desktops ship on Debian, Fedora and Raspberry Pi OS. Do not add an Ubuntu
desktop.

## Checking a change

```
make hooks                   # once: pre-commit (ruff, shellcheck, hygiene)
make lint                    # what CI's lint job runs
pytest tests/ -q             # what CI's unit-tests job runs
make build VARIANT=<base>    # full bake; needs KVM, and sudo for derives
```

A full bake takes tens of minutes and needs KVM, so most changes are
verified by CI's `build-images` run on the pull request. Every change to
`provision/` should come with an assertion in
`cijoe/scripts/image_smoketest.py` (or the desktop or Proxmox smoketest),
since that is the only thing that boots the image. Hardware behaviour (BMC
SOL, real NICs, multi-UART boards) is not reachable in QEMU; say so in the
pull request when a change depends on it.

Changes to `provision/` reach a machine only when it is re-flashed with a
newer image.

## CI pitfalls

`build-images` publishes to GHCR on every push to `main`, on schedule and on
`workflow_dispatch`. Never dispatch it on `main` to diagnose something; open
a throwaway pull request instead, which builds without publishing. A push
that touches only `docs/**`, `README.md`, `AGENTS.md` or `LICENSE` skips the
bake; anything else rebuilds the fleet.

cijoe logs at ERROR by default, so `log.info` in a cijoe script never shows
in CI. Write smoketest verdicts and diagnostics at ERROR. `cijoe-output/`
records only `cijoe.run_local` commands, not subprocess calls.

## Conventions

Conventional Commits with a scope naming the area, e.g. `fix(proxmox):`,
`feat(nbdboot):`, `test(ci):`. Pull requests are merged by rebase only, so
keep each commit self-contained and bisectable. Python follows `ruff.toml`
(line length 100, py311). Shell is checked by shellcheck at warning
severity.

Do parallel work in git worktrees outside the main checkout, e.g.
`git worktree add ../nosi-worktrees/<topic> -b <type>/<topic> origin/main`,
and remove them once merged. `make clean` drops cijoe run output.
