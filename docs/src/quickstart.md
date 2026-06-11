# Quick start

## Build a variant locally

```
make deps                              # install cijoe via pipx
make build VARIANT=debian-13-headless    # build a single variant
make all                               # build every variant
```

The cijoe pipeline downloads the upstream cloud image, resizes it, runs
cloud-init in a QEMU VM, snapshots, and gzip-publishes. The host needs
`qemu-system-x86_64` available and `/dev/kvm` accessible.

Outputs land at `~/system_imaging/disk/nosi-<variant>-x86_64.{qcow2,img.gz,img.gz.sha256}`.

(pull-and-flash)=
## Pull and flash a published image

Each push to `main` publishes to GHCR; the rolling `:latest` tag always
points at the most recent build. [`oras`](https://oras.land) handles
the manifest dance, picks up the canonical filename from the OCI title
annotation we set at push time, and lands the file in the directory of
your choice. It's pre-installed at `/usr/local/bin/oras` on every nosi
image; elsewhere it's a single-binary install from
[oras-project/oras/releases](https://github.com/oras-project/oras/releases).

The [catalog](_generated/catalog.md) lists the currently-published
variants, baked tool versions, and digests.

### Two-step (pull to disk, then flash)

For machines with the headroom for the compressed `.img.gz` plus
whatever `gunzip` needs:

```bash
VARIANT='debian-13-headless'

# pull the latest of any variant into the current dir
# (lands as nosi-<variant>-x86_64.img.gz + sidecars)
oras pull "ghcr.io/safl/nosi/${VARIANT}:latest"

# flash
gunzip -d "nosi-${VARIANT}-x86_64.img.gz" \
    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

### Streaming flash (no intermediate file)

For environments without ~5 GiB of working space (USB rescue stick
flashing the next stick, a nosi box baking another nosi image, etc.),
pull the disk-image blob straight from GHCR, gunzip in flight, write
to the target. Nothing hits the filesystem between GHCR and the
device's first sector:

```bash
VARIANT='debian-13-headless'
REPO="ghcr.io/safl/nosi/${VARIANT}"

# Resolve the .img.gz blob's content-addressed digest from the manifest.
DIGEST=$(oras manifest fetch "${REPO}:latest" \
    | jq -r '.layers[]
             | select(.mediaType=="application/vnd.nosi.disk-image.layer.v1+gzip")
             | .digest')

# Stream-fetch -> gunzip -> dd, all in one pipeline.
oras blob fetch --output - "${REPO}@${DIGEST}" \
    | gunzip -d \
    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Same idea works against the rolling immutable tag (`YYYY.MM.DD-<sha>`)
instead of `:latest` if you want a pinned reference; bty consumes by
blob digest exactly because the digest is the only truly stable name.

`oras repo tags ghcr.io/safl/nosi/<variant>` enumerates the rolling
tags for a variant. See [](release.md) for the rolling-release model.

## Import a WSL2 rootfs (`ubuntu-2604-wsl`)

`ubuntu-2604-wsl` publishes a WSL2 rootfs tarball to its own GHCR
repo (`ubuntu-2604-wsl`).

With [`oras`](https://oras.land) on Windows -- install via `winget`
(Microsoft's official package manager, present on Windows 10/11 out of
the box):

```powershell
winget install -e --id ORASProject.ORAS
```

`scoop install oras` and the direct
[Windows release](https://github.com/oras-project/oras/releases) work
too if you prefer those.

```powershell
oras pull "ghcr.io/safl/nosi/ubuntu-2604-wsl:latest"
wsl --import nosi-wsl "$env:USERPROFILE\WSL\nosi-wsl" nosi-ubuntu-2604-wsl.tar.gz
wsl -d nosi-wsl
```

The imported distro boots with `systemd=true` and default user `odus`
(matching the flashable variant). The first boot regenerates SSH host
keys and the machine-id; `nosi-motd.service` writes the banner. GUI
tools (`meld`, `gitk`, `git-gui`) render via WSLg as native Windows
windows -- no compositor in the rootfs.

## Create a Proxmox CT from an LXC template (`<distro>-lxc`)

The `lxc` shapes (`debian-13-lxc`, `ubuntu-2604-lxc`, `fedora-44-lxc`)
publish a system-container rootfs (`.tar.zst`) that Proxmox consumes
directly as a CT template. On the Proxmox host:

```bash
# Pull the template into a storage's template cache
# (local storage keeps templates in /var/lib/vz/template/cache/).
cd /var/lib/vz/template/cache
oras pull "ghcr.io/safl/nosi/debian-13-lxc:latest"

# Create + start the container (CT id 200, adjust to taste).
pct create 200 local:vztmpl/nosi-debian-13-lxc.tar.zst \
  --hostname nosi-ct --memory 4096 --cores 2 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --rootfs local:8 --unprivileged 1 --features nesting=1
pct start 200
pct enter 200
```

The container runs systemd as PID 1 with the full nosi toolset; user
`odus` and sshd match the flashable variants. `nesting=1` lets podman
run inside the CT. The same tarball imports into Incus / LXD with
`incus image import` (metadata supplied at import time).
