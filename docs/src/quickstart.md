# Quick start

## Build a variant locally

```
make deps                           # install cijoe via pipx
make build VARIANT=debian-sysdev    # build a single variant
make all                            # build every variant
```

The cijoe pipeline downloads the upstream cloud image, resizes it, runs
cloud-init in a QEMU VM, snapshots, and gzip-publishes. The host needs
`qemu-system-x86_64` available and `/dev/kvm` accessible.

Outputs land at `~/system_imaging/disk/nosi-<variant>-x86_64.{qcow2,img.gz,img.gz.sha256}`.

## Flash to a target

Any tool that handles `.img.gz` works:

```
gunzip -d nosi-debian-sysdev-x86_64.img.gz \
    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Boot the target, SSH in as `odus` / `odus.321` (see [](credentials.md)),
rotate the password if it's reachable beyond a trusted network.

## Pull a published image

Each push to `main` publishes to GHCR; the workflow run summary lists the
blob digest. Flash without any registry client:

```
curl -sL 'https://ghcr.io/v2/safl/nosi/<variant>/blobs/sha256:<digest>' \
    | gunzip -d \
    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

See [](release.md) for the rolling-release model and tag scheme.
