#!/usr/bin/env bash
# nosi/provision/steps/26-daemon-prune.sh
#
# Trim background daemons / timers the cloud base images carry but a
# headless dev / appliance box does not want:
#
#   * apt: unattended-upgrades (apt churn at random times), modemmanager
#     (probes /dev/ttyUSB* and breaks USB-serial dev work), packagekit
#     (D-Bus shim that races dpkg for the lock), udisks2 (desktop
#     automounter). Ubuntu also: apport / whoopsie / pollinate
#     (Canonical phone-home), needrestart (prompts at apt time),
#     update-notifier-common, ubuntu-pro-client / ubuntu-advantage-tools.
#   * dnf: ModemManager / PackageKit / udisks2 (same rationale).
#
# Plus systemctl mask on the periodic timers from package_update,
# fwupd, motd-news, man-db cache refreshers, e2scrub, smartd, polkit
# (libs link against it so the package stays; just mask the daemon),
# multipathd (SAN only), networkd-dispatcher (we ship empty hooks).
#
# Idempotency: package purges no-op when the package is absent;
# systemctl mask is idempotent; |true catches "unit not found".

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 26-daemon-prune (distro=$NOSI_DISTRO)"
nosi_require_root

case "$NOSI_DISTRO" in
debian)
    pkgs="unattended-upgrades modemmanager packagekit packagekit-tools
          udisks2 accountsservice"
    ;;
ubuntu)
    pkgs="unattended-upgrades modemmanager packagekit packagekit-tools
          udisks2 accountsservice
          apport whoopsie pollinate needrestart
          update-notifier-common
          ubuntu-pro-client ubuntu-advantage-tools"
    ;;
fedora)
    pkgs="ModemManager PackageKit udisks2"
    ;;
esac

case "$NOSI_PKGMGR" in
apt)
    to_purge=""
    for pkg in $pkgs; do
        if nosi_pkg_installed "$pkg"; then
            to_purge="$to_purge $pkg"
        fi
    done
    if [ -n "$to_purge" ]; then
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get -y purge $to_purge
    fi
    apt-get -y autoremove --purge || true
    ;;
dnf)
    to_remove=""
    for pkg in $pkgs; do
        if nosi_pkg_installed "$pkg"; then
            to_remove="$to_remove $pkg"
        fi
    done
    if [ -n "$to_remove" ]; then
        # shellcheck disable=SC2086
        dnf -y remove $to_remove
    fi
    ;;
esac

case "$NOSI_PKGMGR" in
apt)
    mask_units="apt-daily.service apt-daily.timer
                apt-daily-upgrade.service apt-daily-upgrade.timer
                fwupd.service fwupd-refresh.service fwupd-refresh.timer
                motd-news.service motd-news.timer
                man-db.service man-db.timer
                e2scrub_all.service e2scrub_all.timer e2scrub_reap.service
                polkit.service
                smartd.service
                multipathd.service multipathd.socket
                networkd-dispatcher.service"
    ;;
dnf)
    mask_units="dnf-makecache.service dnf-makecache.timer
                fwupd.service fwupd-refresh.service fwupd-refresh.timer
                man-db-cache-update.service man-db-cache-update.timer
                mlocate-updatedb.timer
                polkit.service
                smartd.service
                abrtd.service abrt-ccpp.service abrt-oops.service
                abrt-vmcore.service abrt-journal-core.service abrt-xorg.service
                multipathd.service multipathd.socket"
    ;;
esac

# shellcheck disable=SC2086
systemctl mask $mask_units 2>/dev/null || true

nosi_info "step 26-daemon-prune done"
