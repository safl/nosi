#!/usr/bin/env bash
# nosi/provision/steps/40-rocm-ernic.sh
#
# ROCm 10 plus the guest side of rocm-ernic (github.com/ROCm/rocm-ernic), an
# emulated ionic RDMA NIC served to QEMU guests over vfio-user. Runs only for
# the *-rocm variants.
#
# ROCm comes from the Ubuntu archive: 26.10 is the first release that
# packages ROCm 10, and AMD's own repositories do not carry a 26.10 suite.
# rdma-core 61+ ships the ionic verbs provider, so userspace is stock.
#
# The kernel side is not stock. rocm-ernic needs the upstream ionic and
# ionic_rdma drivers with its patches applied, built as the ionic-ernic DKMS
# package. Its scripts fetch the driver sources at a kernel tag, and the
# ionic sources only build against a kernel of the same major.minor, so the
# tag is derived from the running kernel rather than rocm-ernic's own pin.
# The scripts and patches are used from a pinned rocm-ernic checkout, which
# stays in /opt/rocm-ernic so the modules can be rebuilt in the guest.
#
# Must run in the booted bake VM (a BASE step), not a chroot: DKMS builds
# for `uname -r`.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

ERNIC_REPO="https://github.com/ROCm/rocm-ernic"
ERNIC_SHA="4880c3428efb8653ca9b9747f67820ecf251b3f8"
ERNIC_DIR=/opt/rocm-ernic
STAMP_DIR=/usr/local/share/rocm-ernic

nosi_info "step 40-rocm-ernic (variant=${NOSI_VARIANT:-?}, distro=$NOSI_DISTRO)"

case "${NOSI_VARIANT:-}" in
*-rocm) : ;;
*)
    nosi_info "not a -rocm variant; skipping"
    exit 0
    ;;
esac
[ "$NOSI_DISTRO" = "ubuntu" ] || nosi_die "the -rocm variants are Ubuntu-only (distro=$NOSI_DISTRO)"
nosi_require_root

kver="$(uname -r)"

# ---- 1. ROCm, the RDMA userspace and the DKMS toolchain ---------------------
# hipcc's clang compiles against the GCC C++ headers; rocm-dev does not pull
# them in, so it needs build-essential alongside.
nosi_pkg_install \
    rocm-dev rocminfo amd-smi build-essential \
    rdma-core ibverbs-providers ibverbs-utils rdmacm-utils perftest \
    libibverbs-dev librdmacm-dev \
    dkms git "linux-headers-${kver}" \
    libnl-3-dev libnl-route-3-dev libudev-dev libsystemd-dev python3-docutils \
    pciutils qemu-guest-agent

# /dev/kfd and /dev/dri/renderD* are group render / video.
usermod -aG render,video odus

# ---- 2. rocm-ernic checkout at the pinned commit ----------------------------
if [ "$(cat "$ERNIC_DIR/.nosi-sha" 2>/dev/null)" != "$ERNIC_SHA" ]; then
    nosi_info "fetching rocm-ernic ${ERNIC_SHA:0:12}"
    rm -rf "$ERNIC_DIR"
    mkdir -p "$ERNIC_DIR"
    curl -fsSL "${ERNIC_REPO}/archive/${ERNIC_SHA}.tar.gz" \
        | tar -xz -C "$ERNIC_DIR" --strip-components=1
    printf '%s\n' "$ERNIC_SHA" > "$ERNIC_DIR/.nosi-sha"
fi

# ---- 3. ionic-ernic DKMS, for every installed kernel ------------------------
# cloud-init's package_upgrade may have installed a newer kernel than the one
# running the bake, and that is the one the image boots.
kref="v$(echo "$kver" | cut -d. -f1-2)"
pkgver="${kref#v}"
scripts="$ERNIC_DIR/ansible/files/scripts"
built_marker="$STAMP_DIR/ionic-ernic.built"
want="${ERNIC_SHA} ${kref}"

if [ "$(cat "$built_marker" 2>/dev/null)" != "$want" ]; then
    src=/var/tmp/ionic-src
    bash "$scripts/fetch-ionic-sources.sh" --source-dir "$src" --kernel-ref "$kref" \
        --patches-dir "$ERNIC_DIR/ansible/files/patches" --force
    bash "$scripts/setup-ionic-dkms.sh" --source-dir "$src" --kernel-ref "$kref"
    rm -rf "$src"
    nosi_write_if_changed "$want" "$built_marker" 0644
fi

for build in /lib/modules/*/build; do
    [ -e "$build" ] || continue
    k="$(basename "$(dirname "$build")")"
    if ! dkms status "ionic-ernic/${pkgver}" -k "$k" 2>/dev/null | grep -q installed; then
        nosi_info "building ionic-ernic for $k"
        dkms install "ionic-ernic/${pkgver}" -k "$k"
    fi
done

# ---- 4. device naming: rocm-ernic0 / rocm-rdma-ernic0 -----------------------
nosi_write_if_changed "$(cat "$ERNIC_DIR/udev/99-rocm-ernic.rules")" \
    /etc/udev/rules.d/99-rocm-ernic.rules 0644

# ---- 5. load ionic_rdma at boot ----------------------------------------------
# ionic autoloads off the PCI alias, but nothing autoloads ionic_rdma, so
# without this the guest gets the netdev and no RDMA device. Loading it
# without the device attached is harmless.
nosi_write_if_changed "ionic_rdma" /etc/modules-load.d/rocm-ernic.conf 0644

# ---- 6. provider stamp for rocm-ernic's ernic_guest_setup ------------------
# The batesste ionic-image convention for "rdma-core came from the archive".
# The role's own check also folds in a GPU-passthrough patch hash, so this
# only satisfies it with ernic_gpu_passthrough off; see provision/README.md.
rdma_ver="$(dpkg-query -W -f='${Version}' rdma-core)"
nosi_write_if_changed "${rdma_ver%%-*}:none" "$STAMP_DIR/provider.stamp" 0644

nosi_info "step 40-rocm-ernic done (ionic-ernic ${pkgver}, rocm-ernic ${ERNIC_SHA:0:12})"
