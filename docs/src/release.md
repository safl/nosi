# Release model

nosi is **rolling**, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` -- immutable,
  dated, traceable
- `ghcr.io/<owner>/<repo>/<variant>:latest` -- moves to the most recent
  publish

Each shape publishes to its own repo named for the full variant
(`ubuntu-2604-headless`, `ubuntu-2604-wsl`, `ubuntu-2604-docker`,
`fedora-44-desktop`, ...) with the same tag scheme. Three artifact
classes ride those repos:

- **disk image** (`.img.gz`) for the flashable shapes (headless,
  desktop) -- an ORAS artifact, `dd`-able.
- **WSL rootfs** (`.tar.gz`) for the wsl shape -- an ORAS artifact,
  `wsl --import`-able.
- **OCI image** for the docker shape -- a genuine container image
  (`docker pull` / a GHA `container:`).

Keeping each shape in its own repo keeps bty's flashable catalog
cleanly scoped to disk images.

## When publishes fire

- push to `main`
- weekly cron, Sunday 03:00 UTC (refresh against upstream package mirrors
  even when nosi itself hasn't changed)
- manual `workflow_dispatch` from the Actions tab

PRs run the full bake + smoketest (and the derives) but do **not** publish.

## What consumers should pin to

The per-build SHA-256 (the OCI blob digest) is the canonical reference.
It's printed on each workflow run's summary page and lives forever; tag
movement (`:latest` advancing, or even `:YYYY.MM.DD-<shortsha>` ever being
re-pushed) never affects a pinned digest reference.

bty consumes by blob digest by default. Any content-addressed tool can do
the same; see [](quickstart.md) for the `curl ... /blobs/sha256:<digest>`
one-liner.

## CI environment

The matrix builds on `ubuntu-24.04` hosted runners with:

- `qemu-system-x86`, `qemu-utils`, `genisoimage`, `cpu-checker` from apt
- `cijoe` installed fresh via pipx
- a udev rule that makes `/dev/kvm` world-readable on the runner (the
  hosted-runner user isn't in the kvm group by default)
- `actions/cache@v4` on `~/system_imaging/cloud` keyed by the variant
  TOML, so subsequent runs skip the cloud-image download

The rolling tag is derived from `${{ github.sha }}` rather than
`git rev-parse` to avoid a `safe.directory` trap when cijoe runs parts of
the build as root.

## ORAS push

The build pushes via [oras-project/setup-oras](https://github.com/oras-project/setup-oras):

```
oras push \
    ghcr.io/<repo>/<variant>:<rolling-tag> \
    --artifact-type application/vnd.nosi.disk-image.v1+gzip \
    <variant>.img.gz:application/vnd.nosi.disk-image.layer.v1+gzip \
    <variant>.img.gz.sha256:text/plain
oras tag ghcr.io/<repo>/<variant>:<rolling-tag> latest
```

The wsl shape pushes the same way with its own artifact type (the
`-wsl` variant has its own repo):

```
oras push \
    ghcr.io/<repo>/<variant>:<rolling-tag> \
    --artifact-type application/vnd.nosi.wsl-rootfs.v1+gzip \
    nosi-<variant>.tar.gz:application/vnd.nosi.wsl-rootfs.layer.v1+gzip \
    nosi-<variant>.tar.gz.sha256:text/plain
oras tag ghcr.io/<repo>/<variant>:<rolling-tag> latest
```

Custom `artifactType` keeps `docker pull` from misinterpreting the ORAS
artifacts as container images, and lets downstream tooling filter
disk-image vs WSL-rootfs. The docker shape is the exception: it's a
genuine OCI image, so it's `docker push`ed (not ORAS) and consumed with
`docker pull` or as a GHA `container:`.
