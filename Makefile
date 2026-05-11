VARIANT ?= debian-base
DISK_IMAGE = $(HOME)/system_imaging/disk/csi-$(VARIANT)-x86_64.qcow2
DIST       = dist

.DEFAULT_GOAL := help

.PHONY: help deps build package clean all

help:
	@echo "csi — headless system image builder for bty"
	@echo
	@echo "Targets:"
	@echo "  deps                 Install cijoe via pipx"
	@echo "  build                Build a single variant (default: debian-base)"
	@echo "  package              Convert built qcow2 to .raw.zst + sha256 in $(DIST)/"
	@echo "  all                  Build every variant"
	@echo "  clean                Remove cijoe artefacts, dist/, and $(DISK_IMAGE)"
	@echo
	@echo "Variant: $(VARIANT) (override with VARIANT=ubuntu-base etc.)"
	@echo "Output:  $(DISK_IMAGE)"

deps:
	pipx install cijoe
	pipx ensurepath

build:
	cijoe tasks/build.yaml --monitor -c configs/$(VARIANT).toml

all:
	$(MAKE) build VARIANT=debian-base
	$(MAKE) build VARIANT=ubuntu-base
	$(MAKE) build VARIANT=fedora-base

package:
	./scripts/package.sh $(VARIANT) $(DIST)

clean:
	rm -rf cijoe-output cijoe-archive $(DIST)
	rm -f $(DISK_IMAGE) $(DISK_IMAGE).sha256
