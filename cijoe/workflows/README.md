# nosi post-flash workflows

Single-step nosi images cover sysdev / aidev with everything bakeable
into one cloud-init pass. Some stacks fundamentally don't fit that
model -- they want kernel-coupled DKMS modules built against the
operator's actual hardware kernel, multi-reboot installer choreography
(MLNX_OFED), or multi-gigabyte toolkits whose release cadence is
decoupled from nosi's. The GPU stacks (NVIDIA + AMD) sit squarely in
that bucket.

**The pattern**: flash one of nosi's Ubuntu 24.04 LTS variants
(`ubuntu-2404-sysdev` / `ubuntu-2404-aidev`, when they exist) on the
target, then run a workflow from this directory against
the running box. cijoe drives the install over SSH, handles the
reboots, and waits for the box to come back. The workflows are direct
ports of [xnvme/aisio's][aisio] equivalents, adjusted for nosi's
constraints (default operator account is `odus`, root SSH is locked).

[aisio]: https://github.com/xnvme/aisio/tree/main/tasks

## What's here

| workflow | what it installs | upstream reference |
|---|---|---|
| `setup_cudadev.yaml` | MLNX_OFED + NVIDIA NOKM driver + CUDA toolkit + GDS | [aisio setup_nvstack.yaml](https://github.com/xnvme/aisio/blob/main/tasks/setup_nvstack.yaml) |
| `setup_rocmdev.yaml` | amdgpu DKMS driver + ROCm user-space stack | [aisio setup_amdstack.yaml](https://github.com/xnvme/aisio/blob/main/tasks/setup_amdstack.yaml) |

Both expect the target to be running Ubuntu 24.04 noble (matching the
kernel pin both vendor stacks qualify against). In nosi terms that's
`ubuntu-2404-sysdev` / `ubuntu-2404-aidev` (the Ubuntu 24.04 variants
exist precisely so the vendor stacks compose). Other distros /
versions are not supported.

## Running

```bash
# 1. (One-time per target) Copy your SSH key to the target so cijoe can
#    drive it without password prompts.
ssh-copy-id odus@<target>

# 2. Make a copy of the example transport config and edit hostname/key.
cp cijoe/workflows/configs/transport.toml.example \
   cijoe/workflows/configs/my-transport.toml
$EDITOR cijoe/workflows/configs/my-transport.toml

# 3. Run the workflow. cijoe SSHes in, runs each step, handles the
#    intermediate reboots.
cd cijoe
cijoe --monitor \
    -c workflows/configs/cudadev.toml \
    -c workflows/configs/my-transport.toml \
    workflows/setup_cudadev.yaml
```

Substitute `rocmdev` for AMD targets. The two workflows are mutually
exclusive on a single host -- pick the GPU you actually have.

## Why this lives in `nosi/cijoe/workflows/` and not in a separate repo

The version pins (NOKM 570, CUDA 12.8, ROCm 7.2) move on their own
cadence; they don't gate on nosi releases. But the workflows
inherently target nosi images (odus user, sudo-NOPASSWD, ssh-pwauth
on, lock_passwd false, the rest of the sysdev baseline), so keeping
them next to the image definitions makes the "this workflow targets
this image" relationship explicit. A separate repo would force a
nosi-version <-> workflow-version compatibility matrix that nobody
wants to maintain.
