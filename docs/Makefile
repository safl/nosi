SPHINXBUILD ?= sphinx-build
SRC          = src
BUILD        = _build

.DEFAULT_GOAL := help

.PHONY: help deps html serve clean

help:
	@echo "nosi docs:"
	@echo "  deps    install sphinx + myst-parser + furo + sphinx-copybutton via pipx"
	@echo "  html    build HTML docs into $(BUILD)/html/"
	@echo "  serve   live-rebuild on edits (sphinx-autobuild) at http://127.0.0.1:8000"
	@echo "  clean   remove $(BUILD)/"

deps:
	pipx install sphinx \
	    --include-deps \
	    --pip-args 'myst-parser sphinx-copybutton furo sphinx-autobuild linkify-it-py'

html:
	$(SPHINXBUILD) -W -b html $(SRC) $(BUILD)/html

serve:
	sphinx-autobuild $(SRC) $(BUILD)/html --host 127.0.0.1 --port 8000

clean:
	rm -rf $(BUILD)
