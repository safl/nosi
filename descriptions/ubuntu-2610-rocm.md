Ubuntu 26.10 (stonking) headless with ROCm 10 from the Ubuntu archive and the
guest side of rocm-ernic: the patched ionic and ionic_rdma drivers built as the
ionic-ernic DKMS package, rdma-core with the ionic provider, and perftest. For
QEMU guests driving rocm-ernic's emulated RDMA NIC, nbdboot, or bare metal.
Non-LTS: it moves to the next Ubuntu release that packages a newer ROCm.
