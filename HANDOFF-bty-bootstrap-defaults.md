# Handoff: bake bty-bootstrap defaults into nosi images

**Status:** addressed (2026-06-06). Both gaps closed in the provision
tree; needs a re-bake + the verify run below to confirm, then notify
the bty side so its workarounds can be retired. Real-world reproduction
on a fresh nosi host (`bty-server` at 10.20.30.200). Two operator
detours during the v0.36.0 bty container-deploy bootstrap; both are
nosi-side gaps, not bty-side bugs.

## What changed

- **Editor default** -- `provision/steps/21-shell-tools.sh` now sets
  `hx` as git `core.editor` (in the system `/etc/gitconfig` /
  FreeBSD `/usr/local/etc/gitconfig` it already manages) and writes
  `/etc/profile.d/nosi-editor.sh` exporting `EDITOR`/`GIT_EDITOR=hx`.
  Implemented as system defaults (`/etc/gitconfig` + `/etc/profile.d`)
  rather than the per-user `git config --global` Problem 1 suggests, so
  they survive operator-account recreation. helix (`hx`) is already
  baked by `20-upstream-tools.sh`, as Problem 1 now notes.
- **Compose provider** -- `podman-compose` added to the `packages:`
  block of all four Linux `.user` files (next to `podman`, same distro
  source as podman itself). `24-podman-setup.sh` now asserts the
  provider is on PATH so a missing/renamed package fails the bake loudly
  instead of surfacing at first `podman compose up`.

## Problem 1 -- `$EDITOR` is unset on a fresh nosi host

The bty quickstart used to read:

```sh
cp envvars.example envvars && $EDITOR envvars && podman compose up -d
```

On a freshly-flashed nosi host `$EDITOR` is unset, so bash expanded
that to `envvars` and tried to exec the values file:

```text
-bash: envvars: command not found
```

Bty worked around this in `bty.deploy._readme` and the `Next:` hint
by writing `"${EDITOR:-vi}"`, but that fallback is belt-and-braces.
The right fix is on the nosi side: ship every image with the user's
actual editor preference baked in.

**Action:** Helix (``hx``) is already bundled in nosi images, so
the only gap is the env-var + git-config defaults pointing at it:

```sh
# In cloud-init runcmd, or the equivalent first-boot hook:
echo 'EDITOR=hx'         >> /etc/environment
echo 'GIT_EDITOR=hx'     >> /etc/environment
# Optionally also drop a /etc/profile.d/editor.sh with the same.
```

For the operator account (if there's a known login user, e.g.
`odus`):

```sh
sudo -u odus git config --global core.editor hx
```

## Problem 2 -- no compose backend on a fresh nosi host

```sh
$ podman compose up -d
Error: looking up compose provider failed
7 errors occurred:
  * exec: "/home/odus/.docker/cli-plugins/docker-compose": ... no such file or directory
  * exec: "/usr/local/lib/docker/cli-plugins/docker-compose": ... no such file or directory
  ... (5 more paths)
  * exec: "docker-compose": executable file not found in $PATH
  * exec: "podman-compose": executable file not found in $PATH
```

`podman compose` is a thin wrapper that looks up an external compose
provider (`docker-compose`, `podman-compose`, or the docker compose
plugin) from PATH. Fresh nosi images have podman but no provider.

The bty deploy README now mentions `pipx install podman-compose` as
the fix, but every operator hitting this for the first time has to
read the error, find the fix, install it, retry. Nosi should bake
it.

**Action (Debian/Ubuntu):**

```sh
apt-get install -y podman-compose
```

Or via pipx (matches the user's tooling preference -- see the
``feedback_python_tooling`` memory in the bty project):

```sh
apt-get install -y pipx
sudo -u $LOGIN_USER pipx install podman-compose
sudo -u $LOGIN_USER pipx ensurepath
```

The apt route is one less moving piece; the pipx route is the user's
default for tools and would mirror how `bty-lab` itself is run
(``uvx`` / ``pipx run``).

## Why bake these in vs. document them

The bty live-env and netboot live-env already bake their own
deps; the bty container-host (a nosi image is the canonical
container host) is the only path where the operator hits these
gaps. Baking them in nosi closes the loop: a fresh nosi image
+ ``uvx bty-lab init && podman compose up -d`` works end-to-end
with zero detours.

Once nosi covers these two, the bty side can drop:

- The ``${EDITOR:-vi}`` fallback in `bty.deploy._readme`,
  `_compose_yaml`, and the runtime `Next:` hint.
- The "Prerequisites" section in the rendered deploy-dir README
  that calls out the compose-provider gap.

Both are pure cleanups in `~/git/bty/src/bty/deploy.py` once nosi
ships these defaults.

## How to pick this up

1. Find the nosi cloud-init / first-boot hook that runs as root
   on freshly-flashed images. (Probably under `provision/` based
   on the repo layout.)
2. Add the two actions above to that hook.
3. Re-bake an image and verify:

       ssh nosi-fresh-host
       echo $EDITOR              # -> hx
       which podman-compose      # -> /usr/bin/podman-compose (or pipx path)
       cd /tmp && uvx bty-lab init bty-host && cd bty-host
       cp envvars.example envvars && hx envvars && podman compose up -d

   That last line is the success criterion: zero "command not
   found" or "compose provider not found" errors.

4. Open a PR; reference this handoff. Then notify the bty side
   so the workarounds can come out.

## Pointers

- bty project memory (full notes):
  `~/.claude/projects/-home-odus-git-bty/memory/project_nosi_editor_defaults.md`
- bty commits that added the workarounds:
  - `ae3c2c3` fix(deploy): quote $EDITOR with vi fallback in the quickstart chain
  - `77efb12` deploy(init): hint at --profile tftp and the compose-backend prereq
- bty deploy module:
  `~/git/bty/src/bty/deploy.py` (the ``_readme`` and the
  ``Next:`` hint at the bottom of ``init_main``).
