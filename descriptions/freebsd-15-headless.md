FreeBSD 15.0-RELEASE headless. C/C++/Python dev base (base clang/lldb +
cmake/meson/ninja/gmake/python, plus gdb/ruff/uv/ lazygit/cijoe); runs the
shared provision chain (NIC-agnostic DHCP, growfs, sshd) via nuageinit;
kernel source in /usr/src. Rust/Zig are opt-in (pkg install) to keep llvm
out of the image.
