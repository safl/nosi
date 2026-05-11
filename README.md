# csi

Automated builder for headless system images consumed by [bty](https://github.com/safl/bty).

The repo is laid out as **generic base images** plus **appliance overlays** built on top of them. Today only base images are scaffolded.

## Scope

| Image          | Distribution      | Arch    | Status |
| -------------- | ----------------- | ------- | ------ |
| `debian-base`  | Debian 13 trixie  | x86_64  | base   |
| `ubuntu-base`  | Ubuntu 26.04 LTS  | x86_64  | base   |
| `fedora-base`  | Fedora (latest)   | x86_64  | base   |

Planned (not yet scaffolded): FreeBSD base, Windows base, appliance overlays.

## How it works

Builds use [mkosi](https://github.com/systemd/mkosi). Each base is a sub-image
under `mkosi.images/`, with shared defaults in the root `mkosi.conf`. Output is
a raw disk image; the `package` target compresses it to `.raw.zst` and emits a
SHA-256 — the two pieces of metadata bty's catalog binds to.

**Images ship anonymous.** No user, no SSH key, no hostname is baked in. The
image contains cloud-init with the datasource pinned to NoCloud — bty (or
whoever does the flashing) is expected to write
`/var/lib/cloud/seed/nocloud/{user-data,meta-data}` at flash time, supplying
per-target identity. SSH host keys and machine-id are stripped at build time
and regenerated on first boot — see `mkosi.finalize.chroot`.

For local testing without bty, `scripts/render-seed.sh` (invoked via
`make render-<image>`) bakes a seed using `$CSI_SSH_PUBKEY` or
`~/.ssh/id_ed25519.pub`. The rendered seed is gitignored and used only by
the next build of that image.

## Quick start

    make deps                    # install mkosi via pipx
    sudo make debian-base        # build debian-base (mkosi needs root)
    sudo make all                # build every base image

    CSI_SSH_PUBKEY=~/.ssh/work_key.pub sudo make all   # override the key

Outputs land in `mkosi.output/` and packaged artifacts in `dist/`.

## Releasing

These images are **rolling**, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<image>:YYYY.MM.DD-<shortsha>` — immutable, sortable, traceable
- `ghcr.io/<owner>/<repo>/<image>:latest` — moves to point at the most recent publish

A publish happens automatically on:

- push to `main` (intentional change to the recipe)
- weekly cron, Sunday 03:00 UTC (refresh against upstream package mirrors)
- manual `workflow_dispatch` from the Actions tab

PR builds run all the way through `make package-*` but do **not** publish.

bty's catalog binds machines to **blob digests**, not tags. The per-build digest
is printed on the workflow run's summary page and lives forever — tag movement
never affects an existing pinned reference.

Consumers can flash directly without any registry client:

    curl -sL 'https://ghcr.io/v2/<owner>/<repo>/<image>/blobs/sha256:<digest>' \
        | zstd -d \
        | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

### CI key handling

No repository secret is required. The workflow fetches the SSH public keys
of the repo owner from `https://github.com/<owner>.keys` at build time —
that endpoint is already public, requires no auth, and reflects whatever you
have configured at <https://github.com/settings/keys>. Key rotation =
update your GitHub account, the next build picks it up.

`GITHUB_TOKEN` is provided automatically and is used for the GHCR push.

## Layout

    mkosi.conf                       # shared defaults (arch, bootloader, common pkgs)
    mkosi.finalize.chroot            # strips baked machine identity at end of build
    mkosi.extra/                     # files copied into every image (datasource pin)
    mkosi.images/
      debian-base/mkosi.conf
      ubuntu-base/mkosi.conf
      fedora-base/mkosi.conf
    scripts/render-seed.sh           # renders per-image cloud-init seed
    scripts/package.sh               # raw -> .raw.zst + sha256
    Makefile                         # build / package / clean entry points
    .github/workflows/build.yml      # CI: matrix build + publish on tag pushes
