VARIANT ?= debian-sysdev

.DEFAULT_GOAL := help

.PHONY: help deps build all clean docs-deps docs-html docs-pdf docs-serve docs-clean

help:
	@echo "nosi: automated builds of Niche Operating System Images (C / Python dev fit)"
	@echo
	@echo "Image targets:"
	@echo "  deps              Install cijoe via pipx"
	@echo "  build             Build one variant (override VARIANT=...)"
	@echo "  all               Build every variant"
	@echo "  clean             Remove cijoe artefacts"
	@echo
	@echo "Docs targets:"
	@echo "  docs-deps         pipx install ./docs/tooling"
	@echo "  docs-html         Build HTML docs into docs/_build/html/"
	@echo "  docs-pdf          Build PDF docs (requires LaTeX)"
	@echo "  docs-serve        Live-rebuild on http://localhost:8000"
	@echo "  docs-clean        Remove docs/_build/"
	@echo
	@echo "Variants:"
	@echo "  debian-sysdev       Debian 13 trixie"
	@echo "  ubuntu-sysdev       Ubuntu 26.04 resolute"
	@echo "  fedora-sysdev       Fedora 44"
	@echo "  ubuntu-aidev        Ubuntu 26.04 + NVIDIA + agentic CLIs"
	@echo "                      (additionally publishes a WSL .tar.gz)"
	@echo
	@echo "Current VARIANT=$(VARIANT)"
	@echo "Output:"
	@echo "  ~/system_imaging/disk/nosi-$(VARIANT)-x86_64.qcow2"
	@echo "  ~/system_imaging/disk/nosi-$(VARIANT)-x86_64.img.gz (+ .sha256)"
	@echo "  ~/system_imaging/disk/nosi-$(VARIANT)-wsl.tar.gz    (aidev only, + .sha256)"

deps:
	pipx install cijoe
	pipx ensurepath

# Build a variant. The cijoe pipeline downloads the upstream cloud image,
# resizes it, runs cloud-init in a QEMU VM, snapshots, and gzip-publishes.
# Needs qemu-system-x86_64 + KVM accessible.
build:
	cd cijoe && cijoe tasks/build.yaml --monitor -c configs/$(VARIANT).toml

all:
	$(MAKE) build VARIANT=debian-sysdev
	$(MAKE) build VARIANT=ubuntu-sysdev
	$(MAKE) build VARIANT=fedora-sysdev
	$(MAKE) build VARIANT=ubuntu-aidev

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
