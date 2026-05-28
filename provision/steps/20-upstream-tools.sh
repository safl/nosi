#!/usr/bin/env bash
# nosi/provision/steps/20-upstream-tools.sh
#
# Install the upstream-release CLIs that nosi baselines on but distro
# packaging either lags or doesn't ship: uv (Astral), rust + rust-analyzer
# (rustup.rs), helix, zellij, lazygit, yazi, taplo (TOML LSP), marksman
# (Markdown LSP), oras (OCI registry CLI).
#
# Each tool installs to /usr/local/bin (or /usr/local/share for runtime
# data). /etc/profile.d/nosi-rust.sh and /etc/profile.d/nosi-helix.sh
# expose RUSTUP_HOME / CARGO_HOME / HELIX_RUNTIME to interactive shells.
#
# Idempotency: re-running redownloads the latest upstream release and
# overwrites the installed binary. That is the intended behaviour for the
# Hetzner-VM use case: `sudo ./20-upstream-tools.sh` becomes a one-shot
# "update everything to upstream latest". Not network-free, not offline.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 20-upstream-tools (distro=$NOSI_DISTRO)"
nosi_require_root

arch=$(uname -m)

# ---- uv + uvx (Astral) ----------------------------------------------------

case "$arch" in
    x86_64)  uv_target=x86_64-unknown-linux-gnu ;;
    aarch64) uv_target=aarch64-unknown-linux-gnu ;;
    *) nosi_die "unsupported arch $arch for uv" ;;
esac
tmp=$(mktemp -d)
curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-${uv_target}.tar.gz" \
    | tar -xz -C "$tmp" "uv-${uv_target}/uv" "uv-${uv_target}/uvx"
install -m 0755 -t /usr/local/bin "$tmp/uv-${uv_target}/uv" "$tmp/uv-${uv_target}/uvx"
rm -rf "$tmp"
uv --version

# ---- rust + rust-analyzer (rustup, system-wide) ---------------------------

export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain stable --profile default
/usr/local/cargo/bin/rustup component add rust-analyzer
nosi_write_if_changed \
'export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
case ":$PATH:" in
    *":/usr/local/cargo/bin:"*) : ;;
    *) export PATH="/usr/local/cargo/bin:$PATH" ;;
esac
' /etc/profile.d/nosi-rust.sh 0644
/usr/local/cargo/bin/rustc --version

# ---- helix editor ---------------------------------------------------------

case "$arch" in
    x86_64)  hx_arch=x86_64-linux ;;
    aarch64) hx_arch=aarch64-linux ;;
    *) nosi_die "unsupported arch $arch for helix" ;;
esac
hx_ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/helix-editor/helix/releases/latest \
    | sed 's#.*/tag/##')
tmp=$(mktemp -d)
curl -fsSL "https://github.com/helix-editor/helix/releases/download/${hx_ver}/helix-${hx_ver}-${hx_arch}.tar.xz" \
    | tar -xJ -C "$tmp"
hx_src="$tmp/helix-${hx_ver}-${hx_arch}"
install -D -m 0755 "$hx_src/hx" /usr/local/bin/hx
mkdir -p /usr/local/share/helix
rm -rf /usr/local/share/helix/runtime
cp -a "$hx_src/runtime" /usr/local/share/helix/runtime
rm -rf "$tmp"
nosi_write_if_changed \
'export HELIX_RUNTIME=/usr/local/share/helix/runtime
' /etc/profile.d/nosi-helix.sh 0644
/usr/local/bin/hx --version

# ---- zellij ---------------------------------------------------------------

case "$arch" in
    x86_64)  zj_target=x86_64-unknown-linux-musl ;;
    aarch64) zj_target=aarch64-unknown-linux-musl ;;
    *) nosi_die "unsupported arch $arch for zellij" ;;
esac
tmp=$(mktemp -d)
curl -fsSL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-${zj_target}.tar.gz" \
    | tar -xz -C "$tmp"
install -m 0755 -t /usr/local/bin "$tmp/zellij"
rm -rf "$tmp"
/usr/local/bin/zellij --version

# ---- lazygit --------------------------------------------------------------

case "$arch" in
    x86_64)  lg_arch=Linux_x86_64 ;;
    aarch64) lg_arch=Linux_arm64 ;;
    *) nosi_die "unsupported arch $arch for lazygit" ;;
esac
lg_ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/jesseduffield/lazygit/releases/latest \
    | sed 's#.*/tag/##' | sed 's/^v//')
tmp=$(mktemp -d)
curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${lg_ver}/lazygit_${lg_ver}_${lg_arch}.tar.gz" \
    | tar -xz -C "$tmp"
install -m 0755 -t /usr/local/bin "$tmp/lazygit"
rm -rf "$tmp"
/usr/local/bin/lazygit --version

# ---- yazi (UI + ya CLI) ---------------------------------------------------

case "$arch" in
    x86_64)  yz_arch=x86_64-unknown-linux-musl ;;
    aarch64) yz_arch=aarch64-unknown-linux-musl ;;
    *) nosi_die "unsupported arch $arch for yazi" ;;
esac
command -v unzip >/dev/null 2>&1 || nosi_pkg_install unzip
tmp=$(mktemp -d)
curl -fsSL -o "$tmp/yazi.zip" \
    "https://github.com/sxyazi/yazi/releases/latest/download/yazi-${yz_arch}.zip"
unzip -q -d "$tmp" "$tmp/yazi.zip"
install -m 0755 -t /usr/local/bin \
    "$tmp/yazi-${yz_arch}/yazi" \
    "$tmp/yazi-${yz_arch}/ya"
rm -rf "$tmp"
/usr/local/bin/yazi --version

# ---- taplo (TOML LSP) -----------------------------------------------------

case "$arch" in
    x86_64)  tp_arch=x86_64 ;;
    aarch64) tp_arch=aarch64 ;;
    *) nosi_die "unsupported arch $arch for taplo" ;;
esac
curl -fsSL "https://github.com/tamasfe/taplo/releases/latest/download/taplo-linux-${tp_arch}.gz" \
    | gunzip > /usr/local/bin/taplo
chmod 0755 /usr/local/bin/taplo
/usr/local/bin/taplo --version

# ---- marksman (Markdown LSP) ----------------------------------------------

case "$arch" in
    x86_64)  mm_arch=x64 ;;
    aarch64) mm_arch=arm64 ;;
    *) nosi_die "unsupported arch $arch for marksman" ;;
esac
curl -fsSL "https://github.com/artempyanykh/marksman/releases/latest/download/marksman-linux-${mm_arch}" \
    -o /usr/local/bin/marksman
chmod 0755 /usr/local/bin/marksman
/usr/local/bin/marksman --version 2>/dev/null \
    || /usr/local/bin/marksman --help >/dev/null

# ---- zig (ziglang.org) ----------------------------------------------------
# Zig ships as a static binary + a sibling lib/ runtime tree; the binary
# resolves its lib via realpath, so /usr/local/zig is the canonical install
# root and /usr/local/bin/zig is a symlink to /usr/local/zig/zig.
# Pinned version: bump as new stable releases land at
# https://ziglang.org/download/. The download index is at
# https://ziglang.org/download/index.json if dynamic discovery is wanted
# later, but pinning keeps the install reproducible across re-runs.
# Tarball naming is `zig-<arch>-linux-<ver>` (arch before os); the
# pre-0.14 `zig-linux-<arch>` ordering is gone, so a version bump that
# crosses that boundary has to keep this order.

zig_ver="0.16.0"
case "$arch" in
    x86_64)  zig_arch=x86_64 ;;
    aarch64) zig_arch=aarch64 ;;
    *) nosi_die "unsupported arch $arch for zig" ;;
esac
tmp=$(mktemp -d)
curl -fsSL "https://ziglang.org/download/${zig_ver}/zig-${zig_arch}-linux-${zig_ver}.tar.xz" \
    -o "$tmp/zig.tar.xz"
rm -rf /usr/local/zig
mkdir -p /usr/local/zig
tar -xJf "$tmp/zig.tar.xz" -C /usr/local/zig --strip-components=1
rm -rf "$tmp"
ln -sf /usr/local/zig/zig /usr/local/bin/zig
/usr/local/bin/zig version

# ---- zls (zig language server, github.com/zigtools/zls) -------------------
# Helix auto-spawns zls from PATH for *.zig buffers (out-of-the-box
# language.toml entry); no editor config needed. Versioned in lockstep
# with zig itself -- zls 0.16.x matches zig 0.16.x and breaks against
# zig master / a mismatched stable. Pin to the same version as zig_ver
# above; bump both together (zls publishes a release per zig stable).

case "$arch" in
    x86_64)  zls_arch=x86_64-linux ;;
    aarch64) zls_arch=aarch64-linux ;;
    *) nosi_die "unsupported arch $arch for zls" ;;
esac
tmp=$(mktemp -d)
curl -fsSL "https://github.com/zigtools/zls/releases/download/${zig_ver}/zls-${zls_arch}.tar.xz" \
    -o "$tmp/zls.tar.xz"
tar -xJf "$tmp/zls.tar.xz" -C "$tmp"
install -m 0755 "$tmp/zls" /usr/local/bin/zls
rm -rf "$tmp"
/usr/local/bin/zls --version

# ---- oras (OCI registry CLI) ----------------------------------------------

case "$arch" in
    x86_64)  or_arch=linux_amd64 ;;
    aarch64) or_arch=linux_arm64 ;;
    *) nosi_die "unsupported arch $arch for oras" ;;
esac
or_ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/oras-project/oras/releases/latest \
    | sed 's#.*/tag/##' | sed 's/^v//')
tmp=$(mktemp -d)
curl -fsSL "https://github.com/oras-project/oras/releases/download/v${or_ver}/oras_${or_ver}_${or_arch}.tar.gz" \
    | tar -xz -C "$tmp"
install -m 0755 -t /usr/local/bin "$tmp/oras"
rm -rf "$tmp"
/usr/local/bin/oras version

nosi_info "step 20-upstream-tools done"
