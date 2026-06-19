# Release model

nosi is **rolling**, not semver. Cadence is **weekly**: one tagged
release per ISO 8601 week. Every publish gets:

- `ghcr.io/<owner>/<repo>/<variant>:YYYY.WNN`, the ISO-week tag
  (e.g. `2026.W25`). Built from `date -u +'%G.W%V'` so the year boundary
  follows ISO 8601's "week 01 contains the year's first Thursday" rule.
- `ghcr.io/<owner>/<repo>/<variant>:latest`, which moves to the most
  recent publish.

**Clobber within the week.** Multiple pushes inside the same ISO week
reuse the same tag: each push to `main` overwrites `:YYYY.WNN` on ghcr
and clobbers the GitHub release with the new artifacts. The W-tag is
NOT immutable within its week; the "weekly" cadence is the cadence of
the tag *name*, not of content freshness. Across weeks the tag is
durable: `:2026.W24` keeps pointing at week 24's last bytes once week 25
starts (unless an ad-hoc hand-triggered rebuild on a `W24`-week date
clobbers it).

Each shape publishes to its own repo named for the full variant
(`ubuntu-2604-headless`, `ubuntu-2604-wsl`, `ubuntu-2604-docker`,
`fedora-44-desktop`, ...) with the same tag scheme. Three artifact
classes ride those repos:

- **disk image** (`.img.gz`) for the flashable shapes (headless,
  desktop): an ORAS artifact, `dd`-able.
- **WSL rootfs** (`.tar.gz`) for the wsl shape: an ORAS artifact,
  consumed by `wsl --import`.
- **OCI image** for the docker shape: a genuine container image
  (`docker pull`, or a GHA `container:`).

Keeping each shape in its own repo keeps bty's flashable catalog
cleanly scoped to disk images.

## When publishes fire

- push to `main`
- weekly cron, Sunday 03:00 UTC (refresh against upstream package mirrors
  even when nosi itself hasn't changed)
- manual `workflow_dispatch` from the Actions tab

PRs run the full bake + smoketest (and the derives) but do **not** publish.

## What consumers should pin to

Two layers of pinning, depending on how much you want to lock down.

**Per-image digest** (most strict). The OCI blob digest
(`sha256:<...>`) is the canonical reference. It's printed on each
workflow run's summary page and lives forever; tag movement (`:latest`
advancing, `:YYYY.WNN` clobbered within its week) never affects a pinned
digest reference.

**Per-release catalog**. Every release ships two catalog files as
release assets:

- `catalog.toml`: image refs pinned to that release's `:YYYY.WNN`
  tag. The URL
  `https://github.com/<owner>/nosi/releases/download/2026.W25/catalog.toml`
  flashes the same bytes every time (subject to the within-week clobber
  rule above; pinning to a *prior* week is fully stable).
- `catalog-latest.toml`: image refs as `:latest`. The rolling escape
  hatch for operators who explicitly want "whatever ghcr currently
  serves".

The `releases/latest/download/` URL prefix resolves to the most recent
release; an operator who wants frozen flashes without the burden of
maintaining a pin can use
`https://github.com/<owner>/nosi/releases/latest/download/catalog.toml`
and each fetch is internally pinned to whatever week was current when
the catalog was fetched.

bty consumes from a catalog URL or by direct blob digest. Any
content-addressed tool can do the same; see [](quickstart.md) for the
`curl ... /blobs/sha256:<digest>` one-liner.

## CI environment

The matrix builds on `ubuntu-24.04` hosted runners with:

- `qemu-system-x86`, `qemu-utils`, `genisoimage`, `cpu-checker` from apt
- `cijoe` installed fresh via pipx
- a udev rule that makes `/dev/kvm` world-readable on the runner (the
  hosted-runner user isn't in the kvm group by default)
- `actions/cache@v4` on `~/system_imaging/cloud` keyed by the variant
  TOML, so subsequent runs skip the cloud-image download

The rolling tag is computed via `date -u +'%G.W%V'` (ISO 8601 year plus
zero-padded ISO week, e.g. `2026.W25`) directly from the runner's clock.
No SHA and no `git rev-parse` is involved, so cijoe running parts of the
build as root cannot trip `safe.directory` when the rolling-tag step
runs later as the runner user.

## ORAS push

The build pushes via [oras-project/setup-oras](https://github.com/oras-project/setup-oras):

```
oras push \
    ghcr.io/<repo>/<variant>:<iso-week-tag> \
    --artifact-type application/vnd.nosi.disk-image.v1+gzip \
    <variant>.img.gz:application/vnd.nosi.disk-image.layer.v1+gzip \
    <variant>.img.gz.sha256:text/plain
oras tag ghcr.io/<repo>/<variant>:<iso-week-tag> latest
```

The wsl shape pushes the same way with its own artifact type (the
`-wsl` variant has its own repo):

```
oras push \
    ghcr.io/<repo>/<variant>:<iso-week-tag> \
    --artifact-type application/vnd.nosi.wsl-rootfs.v1+gzip \
    nosi-<variant>.tar.gz:application/vnd.nosi.wsl-rootfs.layer.v1+gzip \
    nosi-<variant>.tar.gz.sha256:text/plain
oras tag ghcr.io/<repo>/<variant>:<iso-week-tag> latest
```

Custom `artifactType` keeps `docker pull` from misinterpreting the ORAS
artifacts as container images, and lets downstream tooling filter
disk-image vs WSL-rootfs. The docker shape is the exception: it's a
genuine OCI image, so it's `docker push`ed (not ORAS) and consumed with
`docker pull` or as a GHA `container:`.
