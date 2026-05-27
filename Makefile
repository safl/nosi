VARIANT ?= debian-13-sysdev

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
	@echo "Variants (<distro>-<version>-<flavor>):"
	@echo "  debian-13-sysdev    Debian 13 trixie"
	@echo "  ubuntu-2404-aidev   Ubuntu 24.04 noble + agentic CLIs"
	@echo "                      (HW vendor stacks; cudadev/rocmdev workflows pin here)"
	@echo "  ubuntu-2604-sysdev  Ubuntu 26.04 resolute"
	@echo "  ubuntu-2604-aidev   Ubuntu 26.04 resolute + agentic CLIs"
	@echo "                      (additionally publishes a WSL .tar.gz)"
	@echo "  fedora-44-sysdev    Fedora 44"
	@echo "  freebsd-14-sysdev   FreeBSD 14.4-RELEASE (Phase 1 scaffold)"
	@echo "  freebsd-15-sysdev   FreeBSD 15.0-RELEASE (Phase 1 scaffold)"
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
	$(MAKE) build VARIANT=debian-13-sysdev
	$(MAKE) build VARIANT=ubuntu-2404-aidev
	$(MAKE) build VARIANT=ubuntu-2604-sysdev
	$(MAKE) build VARIANT=ubuntu-2604-aidev
	$(MAKE) build VARIANT=fedora-44-sysdev
	$(MAKE) build VARIANT=freebsd-14-sysdev
	$(MAKE) build VARIANT=freebsd-15-sysdev

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
