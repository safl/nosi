.DEFAULT_GOAL := help

.PHONY: help deps html pdf serve clean

help:
	@echo "nosi docs:"
	@echo "  deps    pipx install ./tooling  (provides nosi-docs-{serve,build-html,build-pdf})"
	@echo "  html    nosi-docs-build-html   -> _build/html/"
	@echo "  pdf     nosi-docs-build-pdf    -> _build/latex/nosi.pdf  (requires LaTeX)"
	@echo "  serve   nosi-docs-serve        (live rebuild on http://localhost:8000)"
	@echo "  clean   remove _build/"

deps:
	pipx install ./tooling

html:
	nosi-docs-build-html

pdf:
	nosi-docs-build-pdf

serve:
	nosi-docs-serve

clean:
	rm -rf _build
