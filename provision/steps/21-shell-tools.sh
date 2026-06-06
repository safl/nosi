#!/usr/bin/env bash
# nosi/provision/steps/21-shell-tools.sh
#
# Wire small shell-environment niceties that depend on baseline packages
# already being installed (direnv, fd-find, git-delta):
#
#   * /usr/local/bin/fd -> /usr/bin/fdfind  (Debian/Ubuntu only; the
#     distros name the binary fdfind to avoid colliding with an unrelated
#     `fd` package. Fedora's fd-find ships /usr/bin/fd directly, so the
#     guarded branch is a no-op there.)
#   * /etc/gitconfig with git-delta as the system-wide diff/log/show pager
#     and hx (helix) as core.editor. Per-user ~/.gitconfig still wins, so
#     this is a default, not a lock.
#   * /etc/profile.d/nosi-localbin.sh: `pipx ensurepath` equivalent; puts
#     $HOME/.local/bin on PATH for every interactive shell.
#   * /etc/profile.d/nosi-direnv.sh: bash hook for direnv .envrc loading,
#     guarded on direnv being on PATH.
#   * /etc/profile.d/nosi-editor.sh: EDITOR/GIT_EDITOR=hx so a fresh host
#     has an editor baked in (the bty quickstart's `$EDITOR envvars` line
#     needs it).
#
# Idempotency: nosi_write_if_changed touches mtime only when content
# differs; the fd symlink is guarded on absence.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 21-shell-tools"
nosi_require_root

# ---- FreeBSD: system-wide delta pager at the PREFIX gitconfig path --------
# FreeBSD git reads PREFIX/etc/gitconfig (/usr/local/etc/gitconfig) as its
# system config, not /etc/gitconfig. fd's binary is already `fd` (no fdfind
# alias to bridge). The localbin/direnv profile.d snippets are Linux-only:
# base /etc/profile has no profile.d convention and odus' shell is /bin/sh
# (direnv ships no POSIX-sh hook), so the portable, valuable pieces here are
# the system-wide delta pager and hx as core.editor.
if [ "$NOSI_DISTRO" = "freebsd" ]; then
    nosi_write_if_changed \
'# Managed by nosi/provision/steps/21-shell-tools.sh
[core]
    pager = delta
    editor = hx
[interactive]
    diffFilter = delta --color-only
[delta]
    navigate = true
    line-numbers = true
[merge]
    conflictstyle = zdiff3
' /usr/local/etc/gitconfig 0644
    nosi_info "step 21-shell-tools done (freebsd)"
    exit 0
fi

# ---- fd symlink (Debian/Ubuntu) -------------------------------------------

if [ -x /usr/bin/fdfind ] && [ ! -e /usr/local/bin/fd ]; then
    ln -s /usr/bin/fdfind /usr/local/bin/fd
fi

# ---- /etc/gitconfig with delta pager --------------------------------------

nosi_write_if_changed \
'# Managed by nosi/provision/steps/21-shell-tools.sh
[core]
    pager = delta
    editor = hx
[interactive]
    diffFilter = delta --color-only
[delta]
    navigate = true
    line-numbers = true
[merge]
    conflictstyle = zdiff3
' /etc/gitconfig 0644

# ---- /etc/profile.d/nosi-localbin.sh --------------------------------------

nosi_write_if_changed \
'if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) : ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
fi
' /etc/profile.d/nosi-localbin.sh 0644

# ---- /etc/profile.d/nosi-direnv.sh ----------------------------------------

nosi_write_if_changed \
'if command -v direnv >/dev/null 2>&1; then
    eval "$(direnv hook bash)"
fi
' /etc/profile.d/nosi-direnv.sh 0644

# ---- /etc/profile.d/nosi-editor.sh ----------------------------------------
# Bake the operator's editor as the shell default. hx (helix) is installed
# unconditionally in step 20. Without this, $EDITOR is unset on a fresh
# host and the bty quickstart's `$EDITOR envvars` line expands to bare
# `envvars` and dies with "command not found"; GIT_EDITOR keeps git's
# COMMIT_EDITMSG / rebase-todo flows on hx too (core.editor in /etc/gitconfig
# already covers git; the env vars cover everything else, e.g. crontab, sudoedit).

nosi_write_if_changed \
'export EDITOR=hx
export GIT_EDITOR=hx
' /etc/profile.d/nosi-editor.sh 0644

nosi_info "step 21-shell-tools done"
