# nosi netboot bundle -- build-time production plan

## Goal

Publish, alongside every headless nosi disk image, a matching
`vmlinuz` + `initrd` pair that lets bty nbdboot the image via NBD
using the image's OWN kernel (not bty-media's). Same kernel version
as the image; matched modules; matched userspace glibc; supports both
initramfs-tools (Debian) and dracut (Ubuntu 26.04, Fedora) families.

This is the "shift to build time" landing: the runtime brittleness of
chroot-regen on the bty-server host (DNS from chroot, mirror
availability, GPG timestamp drift, cross-arch qemu-user-static) all
moves back to nosi CI where those inputs are stable.

Variants in scope: `debian-13-headless`, `ubuntu-2404-headless`,
`ubuntu-2604-headless`, `fedora-44-headless`. Not desktop / wsl /
lxc / docker / proxmox. Not FreeBSD (kernel format + boot chain
differ; separate design). Raspberry Pi (arm64) is out of scope for
this pass because bty's netboot path is x86 iPXE today.

## Architecture

Two moving parts, both inside nosi.

### 1. Provision step: `34-netboot-nbdboot-hook.sh`

Runs during the QEMU cloud-init bake, after the base steps but
before the metadata/motd finishers. Guarded on `NOSI_SHAPE=headless`
(or missing, which is the base run's default). Non-headless shapes
skip the step wholesale.

initramfs-tools path (`NOSI_PKGMGR=apt`):
- `nosi_pkg_install nbd-client`
- Drop `/etc/initramfs-tools/scripts/nbdboot`
- Drop `/etc/initramfs-tools/hooks/nosi-nbdboot`
- `update-initramfs -u -k all`

dracut path (`NOSI_PKGMGR=dnf` or Ubuntu 26.04+):
- `nosi_pkg_install nbd` (Fedora) or `nbd-client` (Ubuntu)
- Drop `/etc/dracut.conf.d/99-nosi-netboot.conf` forcing `add_dracutmodules+=" nbd "` and `add_drivers+=" nbd overlay "`
- Drop `/usr/lib/dracut/modules.d/99nosi-nbdboot/module-setup.sh` (install-time module hook)
- Drop `/usr/lib/dracut/modules.d/99nosi-nbdboot/nosi-nbdboot-mount.sh` (runtime attach + overlay)
- `dracut --regenerate-all --force`

Hook assets live under `provision/netboot/` in the repo, copied by
the step. The initramfs-tools `scripts/nbdboot` is the canonical
attach-driver (moved from `bty-media` in a follow-up PR; source of
truth for both frameworks conceptually, though dracut has its own
module shape).

### 2. Pack step: `cijoe/scripts/netboot_bundle_pack.py`

Runs after `img_gz_pack.py`, before publish. Loop-mounts the raw
image (already produced as an intermediate by img_gz_pack), reads
`/boot/vmlinuz-*` and `/boot/initrd.img-*` (Debian/Ubuntu) or
`/boot/vmlinuz-*` and `/boot/initramfs-*.img` (Fedora), and emits:

```
~/system_imaging/disk/nosi-<variant>-netboot-x86_64/
    vmlinuz
    initrd
    manifest.json
```

`manifest.json` fields:
- `variant`, `arch`, `built_at`
- `kernel_version` (from filename)
- `framework` (initramfs-tools | dracut)
- `hook_version` (nosi commit sha at build)
- `source_disk_ref` (the sibling `ghcr.io/safl/nosi/<variant>:<tag>`)
- `sha256` for each file

Tarballed for a single ORAS artifact:
`ghcr.io/safl/nosi/<variant>-netboot:<ROLLING>` +
`:latest`. Media type `application/vnd.nosi.netboot-bundle.v1+tar`.

### Wire contract to bty

Withcache catalog entries gain an optional `netboot_ref` string.
Presence means: this entry can be nbdbooted; nbdmux should fetch the
sibling bundle at warm time and serve its vmlinuz + initrd. Absence
means: flash-only.

pixie's `web/_templates/ipxe/nbdboot.j2` (formerly `bty/ipxe_ramboot.j2`) retargets from `${bty-base}/boot/bty-ramboot-init-*` to the per-export `/artifacts/<export>/{vmlinuz,initrd}` route.

pixie-media's `ramboot-init` variant was deleted in a follow-up PR once the artifacts pipeline shipped.

## Cross-repo sequencing

1. **nosi PR-1** (this session): provision step + hooks + pack
   script. debian-13-headless works end-to-end. Ubuntu + Fedora
   stubbed but not yet wired. No workflow change yet.
2. **nosi PR-2**: dracut module implementation. Ubuntu-26.04 +
   fedora-44 work end-to-end. Local `make build` produces the
   bundle; extraction sanity-checked.
3. **nosi PR-3**: `build.yml` matrix additions to run the pack step
   in CI and oras-push the bundle. `variants.yml` gains
   `netboot: true|false`. `tools/gen_catalog.py` emits
   `netboot_ref` for entries with `netboot: true`.
4. **withcache PR**: schema bump for `netboot_ref` field on catalog
   entries; `/catalog` envelope includes it. Bump minor.
5. **nbdmux PR**: Warmer downloads bundle from `netboot_ref`,
   extracts to `/data/nbdmux/artifacts/<export>/`, adds routes.
6. **downstream (bty then pixie) PR**: `nbdboot.j2` retarget; delete the media-side `ramboot-init` variant.

## Non-goals

- Immediate deletion of bty-media ramboot-init in this session
  (that's step 6 of sequencing above).
- Cross-arch (arm64 headless) support.
- Netboot for FreeBSD.
- Any change to withcache / bty / nbdmux in this session.
