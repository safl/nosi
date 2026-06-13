Debian 13 (trixie) LXC system-container template (zstd rootfs tarball) for
Proxmox CT / Incus. The headless baseline minus kernel / firmware /
NetworkManager; the container shares the host kernel. Drop in template/cache
and `pct create`, or `incus image import`.
