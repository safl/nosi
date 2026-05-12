# Default credentials

Every nosi image ships with:

- **Operator:** `odus` / `odus.321` (passwordless sudo, shell `/bin/bash`)
- **Root:** locked
- **SSH:** password auth enabled on first boot

**Rotate `odus`'s password before exposing the box to anything beyond a
trusted network.**

## Per-instance identity

SSH host keys are *not* baked into the image. They are stripped at the end
of cloud-init; sshd's stock systemd preset regenerates a unique set on first
boot of each flashed instance. The machine-id is wiped the same way.

This closes the obvious MITM hole that would exist if every flashed
instance shared the same host key (anyone with the `.img.gz` would hold
the private key for every deployed box).

## Override at flash time

cloud-init state is cleared at the end of the build, so cloud-init re-runs
on first boot of the flashed instance against whatever seed the flasher
writes. A downstream provisioner (bty, a kickstart pipeline, your own
scripted seeding, ...) can drop a fresh NoCloud seed into
`/var/lib/cloud/seed/nocloud/` to override the defaults: install your own
SSH key, set a hostname, rename the operator account, etc.

If no seed is supplied, the defaults at the top of this page apply.
