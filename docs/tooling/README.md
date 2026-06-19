# nosi-docs

Build and dev-server tooling for the nosi project documentation.

Provides three console scripts:

- `nosi-docs-serve`: live-rebuild dev server on `http://localhost:8000`.
- `nosi-docs-build-html`: one-shot HTML build to `docs/_build/html/`.
- `nosi-docs-build-pdf`: one-shot PDF build via LaTeX to
  `docs/_build/latex/nosi.pdf`.

## Install

From the nosi repo root:

```bash
pipx install ./docs/tooling
```

The PDF build additionally requires a LaTeX distribution (`texlive`
variants on Linux, `latexmk` via MacTeX on macOS).
