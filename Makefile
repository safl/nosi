IMAGES := debian-base ubuntu-base fedora-base
DIST   := dist

RENDER_TARGETS  := $(addprefix render-,$(IMAGES))
PACKAGE_TARGETS := $(addprefix package-,$(IMAGES))

.PHONY: help all clean deps package render-seeds \
        $(IMAGES) $(RENDER_TARGETS) $(PACKAGE_TARGETS)

help:
	@echo "Targets:"
	@echo "  deps                     install mkosi via pipx"
	@echo "  all                      build every base image"
	@echo "  $(IMAGES)"
	@echo "  render-seeds             (re)render cloud-init seed for every image"
	@echo "  package                  package every built image into $(DIST)/"
	@echo "  package-<image>          package a single image"
	@echo "  clean                    remove mkosi outputs, rendered seeds, dist/"
	@echo ""
	@echo "Env:"
	@echo "  CSI_SSH_PUBKEY=/path/key.pub   override SSH key baked into images"

deps:
	# mkosi is not published to PyPI; install straight from the upstream repo.
	pipx install --include-deps git+https://github.com/systemd/mkosi.git

all: $(IMAGES)

# Images ship anonymous — no SSH keys or hostname baked in. bty (or whoever
# flashes) is responsible for writing /var/lib/cloud/seed/nocloud/ at flash
# time. For local testing, see `make render-<image>` below — it bakes a seed
# into mkosi.extra/ for the next build only.
$(IMAGES):
	mkosi --image=$@ build

# Opt-in seed rendering for local testing only. Never invoked by CI.
$(RENDER_TARGETS): render-%: scripts/render-seed.sh
	./scripts/render-seed.sh $*

render-seeds: $(RENDER_TARGETS)

package: $(PACKAGE_TARGETS)

$(PACKAGE_TARGETS): package-%:
	./scripts/package.sh $* $(DIST)

clean:
	-mkosi clean
	rm -rf mkosi.output mkosi.cache mkosi.builddir mkosi.workspace $(DIST)
	rm -rf $(addsuffix /mkosi.extra/var/lib/cloud/seed,$(addprefix mkosi.images/,$(IMAGES)))
