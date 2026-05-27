#!/usr/bin/env bash
# nosi/provision/steps/12-gdb-dashboard.sh
#
# Install gdb-dashboard (github.com/cyrus-and/gdb-dashboard) as the
# system-wide /etc/gdb/gdbinit so every gdb invocation comes up with
# the modular pane layout (source / assembly / registers / stack /
# threads / memory) instead of the terse `(gdb)` prompt.
#
# Why this and not pwndbg / GEF: gdb-dashboard is a single Python file
# loaded by gdb's startup hook -- no extra deps, no venv to maintain,
# no exploit-dev styling. The "step into and inspect" workflow that
# headless operators actually want, beautified.
#
# Distros vary on where gdb's system gdbinit lives. Debian/Ubuntu reads
# /etc/gdb/gdbinit; Fedora reads /etc/gdbinit. Write the dashboard file
# to /etc/gdb/gdbinit and symlink /etc/gdbinit -> there so the same
# source of truth applies on every Linux variant. Operators who want
# stock gdb can `gdb -nx my-binary` for a one-off, or
# `mv /etc/gdb/gdbinit /etc/gdb/gdbinit.disabled` permanently.
#
# Re-running fetches the upstream master tip so a Hetzner-VM re-run
# tracks gdb-dashboard's latest release. The project is single-file,
# no versioned releases; nosi's rolling tag captures whatever was
# current at bake time and a re-run lifts it.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 12-gdb-dashboard"
nosi_require_root

install -d -m 0755 /etc/gdb
curl -fsSL \
    https://raw.githubusercontent.com/cyrus-and/gdb-dashboard/master/.gdbinit \
    -o /etc/gdb/gdbinit
chmod 0644 /etc/gdb/gdbinit

# Fedora's gdb is built with --with-system-gdbinit=/etc/gdbinit (no
# trailing /gdb/). Symlink so the same dashboard config applies. The
# symlink is harmless on Debian/Ubuntu (their gdb reads
# /etc/gdb/gdbinit; the extra /etc/gdbinit just exists).
[ -e /etc/gdbinit ] || ln -s /etc/gdb/gdbinit /etc/gdbinit

# Quick sanity: dashboard's "outermost" marker line. If the upstream
# file is somehow not what we expected (404 redirected to an HTML
# error page, mirror returned the wrong content type, ...), fail the
# step rather than ship a broken /etc/gdb/gdbinit.
grep -q '^python Dashboard.start()' /etc/gdb/gdbinit \
    || nosi_die "downloaded gdb-dashboard does not look like gdb-dashboard"

nosi_info "step 12-gdb-dashboard done"
