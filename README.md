# csi

Automated builder for headless system images consumed by [bty](https://github.com/safl/bty).

Today only base images are scaffolded; appliance overlays are planned.

## Scope

| Image          | Distribution      | Arch    | Status |
| -------------- | ----------------- | ------- | ------ |
| `debian-base`  | Debian 13 trixie  | x86_64  | base   |
| `ubuntu-base`  | Ubuntu 26.04 LTS  | x86_64  | base   |
| `fedora-base`  | Fedora 44         | x86_64  | base   |

Planned: FreeBSD base, Windows base, appliance overlays.

## How it works

Builds use [mkosi](https://github.com/systemd/mkosi). The root `mkosi.conf`
holds settings shared by every variant (architecture, common packages,
bootloader). Each variant is a small distro-specific overlay under
`variants/`; the build composes them with mkosi's `--include`:

    mkosi --include variants/debian-base.conf build

Shared assets — `mkosi.extra/`, `mkosi.postinst.chroot`,
`mkosi.finalize.chroot` — sit at the project root and are auto-discovered by
mkosi for every variant.

`mkosi.finalize.chroot` strips machine-id and `/etc/ssh/ssh_host_*` so each
flashed instance regenerates its own identity on first boot.
`mkosi.postinst.chroot` installs `uv` from Astral's upstream release tarball
(not in Debian/Ubuntu repos) and enables `podman.socket` so docker-socket-
consuming tools work without per-host setup.

## Images ship anonymous

No user, no SSH key, no hostname is baked in at build time. The image
contains cloud-init with the datasource pinned to NoCloud, but the seed
directory is empty. bty (or whoever does the flashing) is expected to write
`/var/lib/cloud/seed/nocloud/{user-data,meta-data}` at flash time, supplying
per-target identity.

## Quick start

    make deps                    # install mkosi via pipx (from upstream git)
    sudo make debian-base        # build debian-base (mkosi needs root)
    sudo make all                # build every base image
    make package                 # compress each .raw to .raw.zst + sha256

Outputs land in `mkosi.output/`; packaged artifacts in `dist/`.

## Releasing

These images are **rolling**, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<image>:YYYY.MM.DD-<shortsha>` — immutable, dated
- `ghcr.io/<owner>/<repo>/<image>:latest` — moves to the most recent publish

A publish happens automatically on:

- push to `main`
- weekly cron, Sunday 03:00 UTC (refresh against upstream package mirrors)
- manual `workflow_dispatch` from the Actions tab

PRs build all the way through `make package-*` but do **not** publish.

bty's catalog binds machines to **blob digests**, not tags. Each per-build
digest is printed on the workflow run's summary page and lives forever; tag
movement never affects a pinned reference.

Consumers can flash directly without any registry client:

    curl -sL 'https://ghcr.io/v2/<owner>/<repo>/<image>/blobs/sha256:<digest>' \
        | zstd -d \
        | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

`GITHUB_TOKEN` is provided automatically by Actions and is the only credential
the workflow uses (for the GHCR push). No repository secret is required.

## Layout

    mkosi.conf                       # shared defaults (arch, common pkgs, bootloader)
    mkosi.extra/                     # shared files copied into every image
    mkosi.postinst.chroot            # uv install + podman.socket enable
    mkosi.finalize.chroot            # strips baked machine identity
    variants/
      debian-base.conf               # Distribution=debian, Release=trixie, ...
      ubuntu-base.conf
      fedora-base.conf
    scripts/package.sh               # raw -> .raw.zst + sha256
    Makefile                         # build / package / clean entry points
    .github/workflows/build.yml      # CI: matrix build + GHCR publish
