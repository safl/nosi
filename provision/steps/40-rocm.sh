#!/usr/bin/env bash
# nosi/provision/steps/40-rocm.sh
#
# ROCm 10 and the RDMA userspace, from the Ubuntu archive. Runs only for the
# *-rocm variants.
#
# ROCm comes from the Ubuntu archive: 26.10 is the first release that
# packages ROCm 10, and AMD's own repositories do not carry a 26.10 suite.
# rdma-core 61+ ships the ionic verbs provider, and the kernel's in-tree
# ionic drivers serve it.
#
# Only stock packages: the image is flashed onto real machines too, so
# drivers patched for emulated devices are installed by whoever tests with
# those devices, at test time. dkms and the headers are here so that such a
# package installs without pulling a toolchain first.
#
# Must run in the booted bake VM (a BASE step), not a chroot: the headers
# are for `uname -r`.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 40-rocm (variant=${NOSI_VARIANT:-?}, distro=$NOSI_DISTRO)"

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

# hipcc's clang compiles against the GCC C++ headers; rocm-dev does not pull
# them in, so it needs build-essential alongside.
nosi_pkg_install \
    rocm-dev rocminfo amd-smi build-essential \
    rdma-core ibverbs-providers ibverbs-utils rdmacm-utils perftest \
    libibverbs-dev librdmacm-dev \
    dkms "linux-headers-${kver}" \
    pciutils qemu-guest-agent

# /dev/kfd and /dev/dri/renderD* are group render / video.
usermod -aG render,video odus

nosi_info "step 40-rocm done"
