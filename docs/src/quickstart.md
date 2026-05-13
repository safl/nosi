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

## Import a WSL2 rootfs (`ubuntu-aidev` only)

`ubuntu-aidev` additionally publishes a WSL2 rootfs tarball to a sibling
GHCR repo (`<variant>-wsl`). Paste-once flow in PowerShell -- no manual
digest lookup, resolves the `:latest` tag and lands the tarball with
its canonical filename:

```powershell
# Pull the latest nosi-ubuntu-aidev WSL rootfs from GHCR
$repo = 'safl/nosi/ubuntu-aidev-wsl'
$tarball = 'nosi-ubuntu-aidev-wsl.tar.gz'
$token = (Invoke-RestMethod "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull").token
$accept = 'application/vnd.oci.image.manifest.v1+json'
$manifest = Invoke-RestMethod -Headers @{Authorization="Bearer $token"; Accept=$accept} `
    "https://ghcr.io/v2/$repo/manifests/latest"
$digest = ($manifest.layers | Where-Object { $_.mediaType -like '*wsl-rootfs.layer*' }).digest
Invoke-WebRequest -Headers @{Authorization="Bearer $token"} `
    "https://ghcr.io/v2/$repo/blobs/$digest" -OutFile $tarball

# Import into WSL2 and launch
wsl --import nosi-aidev "$env:USERPROFILE\WSL\nosi-aidev" $tarball
wsl -d nosi-aidev
```

Or, if you have [`oras`](https://oras.land) installed (e.g. via
`scoop install oras`), the same flow is two lines:

```powershell
oras pull "ghcr.io/safl/nosi/ubuntu-aidev-wsl:latest"
wsl --import nosi-aidev "$env:USERPROFILE\WSL\nosi-aidev" nosi-ubuntu-aidev-wsl.tar.gz
wsl -d nosi-aidev
```

The imported distro boots with `systemd=true` and default user `odus`
(matching the flashable variant). The first boot regenerates SSH host
keys and the machine-id; `nosi-motd.service` writes the banner.
