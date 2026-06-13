Fedora 44 LXC system-container template (zstd rootfs tarball) for Proxmox CT
/ Incus. The headless baseline minus kernel / firmware / NetworkManager
(systemd-networkd drives the container network); shares the host kernel.
Drop in template/cache and `pct create`.
