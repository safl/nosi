#!/usr/bin/env bash
# nosi/provision/steps/27-snapd-purge.sh
#
# Drop snapd on Ubuntu. Ubuntu cloud images ship it preinstalled; sysdev
# / aidev do not use snaps (apt + podman cover the same ground) and
# snapd's auto-refresh timer + squashfs loop mounts add measurable
# runtime overhead on a flashed bare-metal box.
#
# Remove installed snaps first so apt can unmount their loops, then
# purge snapd and hold it so a future package_upgrade can't drag it
# back in via a Recommends/Depends chain.
#
# No-op on Debian (snapd not installed) and Fedora (not an apt distro,
# rpm world has no equivalent of `apt-mark hold` here). Gated on the
# presence of /usr/bin/snap so a re-run after purge is also a no-op.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 27-snapd-purge"

if [ "$NOSI_DISTRO" != "ubuntu" ]; then
    nosi_info "non-ubuntu distro ($NOSI_DISTRO); skipping"
    exit 0
fi

nosi_require_root

if command -v snap >/dev/null 2>&1; then
    # Iterate a few times: some snaps refuse removal until their
    # dependents go (e.g. core / snapd base is last).
    for _ in 1 2 3; do
        snaps=$(snap list 2>/dev/null | awk 'NR>1 {print $1}') || true
        [ -z "$snaps" ] && break
        for s in $snaps; do
            snap remove --purge "$s" 2>/dev/null || true
        done
    done
fi

if nosi_pkg_installed snapd; then
    DEBIAN_FRONTEND=noninteractive apt-get -y purge snapd
fi
apt-mark hold snapd 2>/dev/null || true
rm -rf /root/snap /home/*/snap /snap /var/snap /var/lib/snapd /var/cache/snapd

nosi_info "step 27-snapd-purge done"
