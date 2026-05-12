# Release model

nosi is **rolling**, not semver. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.MM.DD-<shortsha>` -- immutable,
  dated, traceable
- `ghcr.io/<owner>/<repo>/<variant>:latest` -- moves to the most recent
  publish

## When publishes fire

- push to `main`
- weekly cron, Sunday 03:00 UTC (refresh against upstream package mirrors
  even when nosi itself hasn't changed)
- manual `workflow_dispatch` from the Actions tab

PRs build all the way through `make package` but do **not** publish.

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

Custom `artifactType` keeps `docker pull` from misinterpreting these as
container images.
