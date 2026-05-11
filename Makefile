IMAGES := debian-base ubuntu-base fedora-base
DIST   := dist

PACKAGE_TARGETS := $(addprefix package-,$(IMAGES))

.PHONY: help all clean deps package $(IMAGES) $(PACKAGE_TARGETS)

help:
	@echo "Targets:"
	@echo "  deps                     install mkosi via pipx (from upstream git)"
	@echo "  all                      build every base image"
	@echo "  $(IMAGES)"
	@echo "  package                  package every built image into $(DIST)/"
	@echo "  package-<image>          package a single image"
	@echo "  clean                    remove mkosi outputs and dist/"

deps:
	# mkosi is not published to PyPI; install straight from the upstream repo.
	pipx install --include-deps git+https://github.com/systemd/mkosi.git

all: $(IMAGES)

# Build each variant by overlaying its distro-specific config on top of the
# shared mkosi.conf. ImageId comes from the variant config and drives the
# output filename (mkosi.output/csi-<image>.raw).
$(IMAGES):
	mkosi --include variants/$@.conf build

package: $(PACKAGE_TARGETS)

$(PACKAGE_TARGETS): package-%:
	./scripts/package.sh $* $(DIST)

clean:
	-mkosi clean
	rm -rf mkosi.output mkosi.cache mkosi.builddir mkosi.workspace $(DIST)
