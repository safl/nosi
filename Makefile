VARIANT ?= debian-base

.DEFAULT_GOAL := help

.PHONY: help deps build all clean

help:
	@echo "nosi — headless system image builder for bty"
	@echo
	@echo "Targets:"
	@echo "  deps              Install cijoe via pipx"
	@echo "  build             Build one variant (override VARIANT=...)"
	@echo "  all               Build every variant"
	@echo "  clean             Remove cijoe artefacts"
	@echo
	@echo "Variants:"
	@echo "  debian-base       Debian 13 trixie"
	@echo "  ubuntu-base       Ubuntu 24.04 noble"
	@echo "  fedora-base       Fedora 43"
	@echo
	@echo "Current VARIANT=$(VARIANT)"
	@echo "Output:"
	@echo "  ~/system_imaging/disk/nosi-$(VARIANT)-x86_64.qcow2"
	@echo "  ~/system_imaging/disk/nosi-$(VARIANT)-x86_64.img.gz (+ .sha256)"

deps:
	pipx install cijoe
	pipx ensurepath

# Build a variant. The cijoe pipeline downloads the upstream cloud image,
# resizes it, runs cloud-init in a QEMU VM, snapshots, and gzip-publishes.
# Needs qemu-system-x86_64 + KVM accessible.
build:
	cd cijoe && cijoe tasks/build.yaml --monitor -c configs/$(VARIANT).toml

all:
	$(MAKE) build VARIANT=debian-base
	$(MAKE) build VARIANT=ubuntu-base
	$(MAKE) build VARIANT=fedora-base

clean:
	rm -rf cijoe/cijoe-output cijoe/cijoe-archive
