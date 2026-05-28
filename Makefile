VARIANT ?= debian-13-headless

.DEFAULT_GOAL := help

.PHONY: help deps build all clean docs-deps docs-html docs-pdf docs-serve docs-clean

help:
	@echo "nosi: automated builds of Niche Operating System Images (C / C++ / Python / Rust / Zig dev fit)"
	@echo
	@echo "Image targets:"
	@echo "  deps              Install cijoe via pipx"
	@echo "  build             Build one base (override VARIANT=...); derived shapes ride along"
	@echo "  all               Build every base"
	@echo "  clean             Remove cijoe artifacts"
	@echo
	@echo "Docs targets:"
	@echo "  docs-deps         pipx install ./docs/tooling"
	@echo "  docs-html         Build HTML docs into docs/_build/html/"
	@echo "  docs-pdf          Build PDF docs (requires LaTeX)"
	@echo "  docs-serve        Live-rebuild on http://localhost:8000"
	@echo "  docs-clean        Remove docs/_build/"
	@echo
	@echo "Bakeable bases (VARIANT=...); each base also produces its derived shapes:"
	@echo "  debian-13-headless    Debian 13 trixie"
	@echo "  ubuntu-2404-headless  Ubuntu 24.04 noble (HW vendor stacks; cudadev/rocmdev pin here)"
	@echo "  ubuntu-2604-headless  Ubuntu 26.04 resolute -> derives ubuntu-2604-wsl + ubuntu-2604-docker"
	@echo "  fedora-44-headless    Fedora 44 -> derives fedora-44-desktop"
	@echo "  freebsd-14-headless   FreeBSD 14.4-RELEASE (Phase 1 scaffold)"
	@echo "  freebsd-15-headless   FreeBSD 15.0-RELEASE (Phase 1 scaffold)"
	@echo
	@echo "Derived shapes (built by their base, not a standalone 'make build VARIANT='):"
	@echo "  ubuntu-2604-wsl       WSL2 rootfs .tar.gz (meld/gitk/git-gui via WSLg)"
	@echo "  ubuntu-2604-docker    OCI image (CI bootstrap host; docker pull / GHA container:)"
	@echo "  fedora-44-desktop     Sway desktop .img.gz (personal laptop)"
	@echo
	@echo "Current VARIANT=$(VARIANT)"
	@echo "Output (base):"
	@echo "  ~/system_imaging/disk/nosi-$(VARIANT)-x86_64.qcow2"
	@echo "  ~/system_imaging/disk/nosi-$(VARIANT)-x86_64.img.gz (+ .sha256)"
	@echo "Derived shapes (ubuntu-2604 / fedora-44 bases) land alongside as"
	@echo "  nosi-<variant>.tar.gz (wsl) / nosi-<variant>-x86_64.img.gz (desktop) / a local OCI image (docker)"

deps:
	pipx install cijoe
	pipx ensurepath

# Build a base. The cijoe pipeline downloads the upstream cloud image,
# resizes it, runs cloud-init in a QEMU VM, snapshots, gzip-publishes,
# and (for bases with a [[...derive]] list) derives their shapes from
# the baked rootfs. Needs qemu-system-x86_64 + KVM; deriving needs sudo
# for qemu-nbd + chroot (and docker for the docker shape).
build:
	cd cijoe && cijoe tasks/build.yaml --monitor -c configs/$(VARIANT).toml

# Only the bases. ubuntu-2604-wsl / ubuntu-2604-docker / fedora-44-desktop
# are produced by their base's build, not invoked here.
all:
	$(MAKE) build VARIANT=debian-13-headless
	$(MAKE) build VARIANT=ubuntu-2404-headless
	$(MAKE) build VARIANT=ubuntu-2604-headless
	$(MAKE) build VARIANT=fedora-44-headless
	$(MAKE) build VARIANT=freebsd-14-headless
	$(MAKE) build VARIANT=freebsd-15-headless

clean:
	rm -rf cijoe/cijoe-output cijoe/cijoe-archive

# ---------- Docs --------------------------------------------------------

docs-deps:
	$(MAKE) -C docs deps

docs-html:
	$(MAKE) -C docs html

docs-pdf:
	$(MAKE) -C docs pdf

docs-serve:
	$(MAKE) -C docs serve

docs-clean:
	$(MAKE) -C docs clean
