Ubuntu 26.04 LTS (resolute) OCI/container image: the headless baseline (qemu
+ cijoe included) CI-tuned (no systemd as PID1; kernel / boot / cloud-init
stripped). A bootstrap host that launches qemu guests via cijoe (nested KVM
on GHA with --privileged, or device passthrough on bare metal), and a
general dev base for a project's `make docker`. Pull with docker; use as a
GHA job container.
