#!/usr/bin/env bash
# nosi/provision/steps/50-desktop-stack.sh
#
# desktop shape only. Configures the Sway-based desktop stack:
#
#   * greetd + tuigreet as the system display manager, defaulting to
#     a sway session
#   * opinionated default configs for sway / swaylock / waybar / foot /
#     fuzzel / mako under /etc/skel/.config/
#   * mirror of those defaults into /home/odus/.config/ so the baked
#     operator account boots into a usable desktop on first login
#   * graphical.target as the default systemd target
#   * cups.socket + avahi-daemon enabled so printing works on first
#     boot (lazy-activates the daemon when a print actually fires)
#
# The configs target a CLI-heavy operator's muscle memory:
#
#   Super + Return  foot
#   Super + Space   fuzzel (app launcher)
#   Super + E       thunar (file manager)
#   Super + L       swaylock (screen lock)
#   Super + Q       kill focused window
#   Super + 1..9    switch workspace
#   Print           screenshot whole screen to clipboard
#   Shift + Print   screenshot region to clipboard
#   XF86 Brightness brightnessctl 10% step
#   XF86 Volume     wpctl 5% step, Mute toggles
#
# Idempotency: every config file gets rewritten on each run (cheap +
# deterministic). systemctl enable + set-default are idempotent.
# /home/odus's config is copied with `cp -n` so an operator's manual
# edits survive a re-apply.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 50-desktop-stack (shape=${NOSI_SHAPE:-?})"

if [ "${NOSI_SHAPE:-}" != "desktop" ]; then
    nosi_info "non-desktop shape; skipping"
    exit 0
fi

nosi_require_root

# ---- desktop packages -----------------------------------------------
# The Sway Wayland stack + greeter + browser + GUI git tools (meld /
# gitk / git-gui) + audio / bluetooth / power / printing. Installed
# HERE rather than in cloud-init so
# `apply.sh <distro>-desktop` fully defines the desktop shape: a
# vanilla-VM operator reaches the same result as the baked image, and
# the derive-from-headless build only has to run this one step on the
# baked headless rootfs. Fedora (dnf) and Debian/Ubuntu + Raspberry Pi OS
# (apt) carry the same Sway stack under different package names; GREETER_CMD
# captures the per-distro greetd greeter, expanded into the greetd config
# below.
case "${NOSI_PKGMGR:-}" in
dnf)
    nosi_pkg_install \
        sway swaylock swayidle swaybg \
        xdg-desktop-portal-wlr lxpolkit \
        foot waybar fuzzel mako wl-clipboard cliphist grim slurp \
        greetd tuigreet \
        firefox \
        Thunar gvfs thunar-volman tumbler \
        librsvg2-tools \
        meld gitk git-gui \
        pipewire pipewire-pulseaudio wireplumber pavucontrol \
        brightnessctl bluez bluez-tools power-profiles-daemon playerctl \
        network-manager-applet \
        cups cups-filters cups-pdf avahi avahi-tools system-config-printer \
        google-noto-sans-fonts google-noto-color-emoji-fonts \
        xdg-utils xdg-desktop-portal
    GREETER_CMD="tuigreet --time --remember --remember-user-session --asterisks --greeting 'nosi' --cmd sway"
    ;;
apt)
    # Debian package names for the same stack: mako -> mako-notifier,
    # pipewire-pulseaudio -> pipewire-pulse, cups-pdf -> printer-driver-cups-pdf,
    # avahi -> avahi-daemon + avahi-utils, the noto fonts as fonts-noto-*.
    # firefox-esr is the Debian-main browser (the `firefox` snap/name isn't in
    # Debian/RPi OS main). fontconfig is named explicitly for fc-cache below.
    nosi_pkg_install \
        sway swaylock swayidle swaybg \
        xdg-desktop-portal-wlr lxpolkit \
        foot waybar fuzzel mako-notifier wl-clipboard cliphist grim slurp \
        greetd \
        firefox-esr \
        thunar gvfs thunar-volman tumbler \
        librsvg2-bin \
        meld gitk git-gui \
        pipewire pipewire-pulse wireplumber pavucontrol \
        brightnessctl bluez bluez-tools power-profiles-daemon playerctl \
        network-manager-applet \
        cups cups-filters printer-driver-cups-pdf avahi-daemon avahi-utils system-config-printer \
        fonts-noto-core fonts-noto-color-emoji fontconfig \
        xdg-utils xdg-desktop-portal
    # greetd greeter: Debian trixie (and RPi OS, which mirrors it) packages
    # tuigreet as plain `tuigreet`; probing only the `greetd-tuigreet` name
    # silently shipped the bare agreety fallback on every apt desktop. Try
    # both names, best-effort; fall back to `agreety` (greetd's built-in
    # minimal greeter) only if neither lands, so greeter packaging drift
    # still never hard-fails the bake.
    if { nosi_pkg_install tuigreet 2>/dev/null || nosi_pkg_install greetd-tuigreet 2>/dev/null; } \
        && command -v tuigreet >/dev/null 2>&1; then
        GREETER_CMD="tuigreet --time --remember --remember-user-session --asterisks --greeting 'nosi' --cmd sway"
    else
        nosi_warn "tuigreet unavailable; falling back to agreety greeter"
        GREETER_CMD="agreety --cmd sway"
    fi
    ;;
*)
    nosi_die "desktop shape supports dnf (Fedora) and apt (Debian/Ubuntu/RPi OS) only; got pkgmgr=${NOSI_PKGMGR:-?}"
    ;;
esac

# ---- desktop networking: hand the link to NetworkManager ------------
# The headless base (step 08) sets the netplan renderer to systemd-networkd:
# fine for a server, but on a desktop it leaves NetworkManager managing
# nothing. nmtui and the applet show no connection, and a WireGuard / VPN
# connection can't be created because the device is "unmanaged". A desktop
# operator expects NM to own networking. Fedora and Raspberry Pi OS desktops
# are already NM-managed, so this is the apt + netplan (Debian/Ubuntu) case:
# flip the renderer to NetworkManager (no ethernets block, so NM manages every
# device with its default auto-DHCP), stand systemd-networkd down so the two
# don't fight over the NIC, and make sure NM is enabled. Config-only and
# takes effect on the next boot, like step 08.
if [ "${NOSI_PKGMGR:-}" = "apt" ] && command -v netplan >/dev/null 2>&1; then
    nosi_info "desktop: handing networking to NetworkManager (was networkd)"
    nosi_write_if_changed \
'# Managed by nosi/provision/steps/50-desktop-stack.sh
# Desktop networking via NetworkManager so nmtui / the applet / WireGuard work.
# No ethernets block: NM manages every device and DHCPs wired NICs by default.
network:
  version: 2
  renderer: NetworkManager
' /etc/netplan/50-nosi.yaml 0600
    systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
    systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl enable NetworkManager.service 2>/dev/null || true
    netplan generate 2>/dev/null || nosi_warn "netplan generate (NetworkManager renderer) failed"
fi

# ---- desktop seat access --------------------------------------------
# The headless base puts odus in wheel + kvm only. The desktop shape
# needs `video` (DRM render nodes) and `input` (evdev: lid / keyboard /
# touchpad) for a Wayland seat. Additive + idempotent; guarded so it's
# a no-op on a system without the odus operator account.
if id odus >/dev/null 2>&1; then
    usermod -aG video,input odus || true
fi

# ---- greetd greeter account -----------------------------------------
# greetd runs its greeter as an unprivileged user (config.toml's
# `user = "greeter"` below). Fedora's greetd rpm creates `greeter`, but
# Debian / Raspberry Pi OS's apt package instead names it `_greetd` and
# only creates it from a maintainer script that does NOT fire inside the
# chroot bake -- so on the apt desktop no `greeter` user exists and
# greetd crash-loops at boot with "configured default session user
# 'greeter' not found", hitting the start limit and dropping the box to
# a text login with no desktop. Ensure the account the config names
# exists, with the video/input groups a Wayland greeter needs. Guarded
# so it is a no-op where the distro already provides `greeter`.
if ! id greeter >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home \
        --home-dir /var/lib/greetd --shell /usr/sbin/nologin greeter
fi
usermod -aG video,input greeter 2>/dev/null || true
install -d -o greeter -g greeter -m 0755 /var/lib/greetd /var/cache/greetd

# ---- JetBrainsMono Nerd Font ----------------------------------------
# waybar / foot / fuzzel / mako all use the Nerd Font glyphs (battery
# / audio / wifi icons). Not packaged on Fedora 44 mainline (and the
# Debian / Ubuntu packages lag the upstream release), so install the
# upstream Nerd Fonts release tarball directly. Idempotent: skipped if
# the destination directory already exists.
NERD_FONT_DEST="/usr/local/share/fonts/JetBrainsMonoNerdFont"
if [ ! -d "$NERD_FONT_DEST" ]; then
    nerd_tmp="$(mktemp -d)"
    nerd_url="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"
    curl -fsSL "$nerd_url" -o "$nerd_tmp/JetBrainsMono.zip"
    install -d -m 0755 "$NERD_FONT_DEST"
    unzip -q "$nerd_tmp/JetBrainsMono.zip" -d "$NERD_FONT_DEST"
    rm -rf "$nerd_tmp"
    fc-cache -f
fi

# ---- greetd ---------------------------------------------------------
# Launch tuigreet on vt7, default to sway. --remember +
# --remember-user-session save the chosen user + session command to
# /var/cache/greetd/state.toml so the operator's last selection
# carries across reboots. --asterisks shows password masking instead
# of nothing. Greeting line keeps it on-brand.
#
# vt = 7 (NOT 1): the kernel + systemd console lands on the foreground VT
# (the base cmdline carries console=tty0 console=ttyS1 console=ttyS0), so a
# greeter on vt1 gets scribbled over by late-boot "[ OK ] Started ..."
# lines and kernel chatter, a torn greeter. tty7 is the conventional
# display-manager VT (the packaged greetd.service already
# Conflicts=getty@tty7), so the greeter renders clean there and tty1
# keeps its normal boot console + login.
#
# Heredoc is unquoted so ${GREETER_CMD} (set per-distro above) expands; the
# rest of the file carries no shell metacharacters, so expansion is safe.
install -d -m 0755 /etc/greetd
cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 7

[default_session]
command = "${GREETER_CMD}"
user = "greeter"
EOF
chmod 0644 /etc/greetd/config.toml

# ---- greetd PAM ----------------------------------------------------
# greetd authenticates through the ``greetd`` PAM service. Debian / RPi
# OS's apt package ships /etc/pam.d/greetd, so the greeter works there.
# Fedora's greetd rpm ships NO PAM file, so PAM falls through to
# /etc/pam.d/other (deny) and EVERY greeter login fails with an
# authentication error -- even with the right password (the account is
# fine; only the greeter's auth path is broken). Provide one when it is
# missing: include the system login stack (both distros ship
# /etc/pam.d/login), so the greeter authenticates exactly like a console
# login. Create-if-missing leaves a distro-provided file untouched.
if [ ! -f /etc/pam.d/greetd ]; then
    nosi_info "writing /etc/pam.d/greetd (Fedora's greetd rpm ships none)"
    cat > /etc/pam.d/greetd <<'PAM'
#%PAM-1.0
auth       include      login
account    include      login
password   include      login
session    include      login
PAM
    chmod 0644 /etc/pam.d/greetd
fi

# ---- Sway config ----------------------------------------------------
install -d -m 0755 /etc/skel/.config/sway
cat > /etc/skel/.config/sway/config <<'EOF'
# nosi default sway config. Copied from /etc/skel/.config/sway/ on
# first login; personalise in place, nosi never overwrites it.
# Reference: https://github.com/swaywm/sway/wiki

# Mod = Super (left Windows key)
set $mod Mod4

# Programs
set $term foot
set $menu fuzzel
set $lockcmd swaylock
set $filemanager thunar

# Output: autodetect; sway handles hotplug. Wallpaper is a calm
# solid color out of the Catppuccin Mocha base palette; operators
# swap in their own with `output * bg /path/to/file.png fill` or
# `output * bg #<hex> solid_color` from the sway config.
output * bg #1e1e2e solid_color

# Stock sway can't round window corners (that's a swayfx feature, not
# in F44 mainline). Foot terminal carries its own alpha (~0.90, see
# foot.ini) so it's translucent over the wallpaper / other windows.
# Waybar IS rounded (border-radius in style.css); the per-window
# rounding is the bit operators trade up to swayfx for.

# Input
input * {
    xkb_layout us
    # Caps Lock becomes another Control (no Caps Lock). Standard
    # CLI-operator remap; applies to every keyboard.
    xkb_options ctrl:nocaps
    natural_scroll enabled
    tap enabled
}

# Gaps + borders -- i3-gaps style: roomier than the default, smart_*
# variants drop the gap when only one window is on screen so a single
# foot fills the workspace edge-to-edge.
gaps inner 8
gaps outer 16
smart_borders on
smart_gaps on
default_border pixel 2
default_floating_border pixel 2
# titlebar_padding must be >= 1 (sway rejects 0 with "errors in your
# config file"); harmless with pixel borders, which draw no titlebar.
titlebar_padding 1

# Focus follows the click, not the mouse motion.
focus_follows_mouse no

# Autostart
# Apply HiDPI output scaling first so waybar + dialogs size correctly on
# a 4K/QHD panel (sway has no built-in DPI awareness; see nosi-autoscale).
exec nosi-autoscale
exec nm-applet --indicator
exec nosi-waybar
exec mako
exec lxpolkit
exec wl-paste --watch cliphist store
# swayidle: lock after 5 min, screen off after 10, suspend after 15.
exec swayidle -w \
    timeout 300 'swaylock -f' \
    timeout 600 'swaymsg "output * dpms off"' \
        resume 'swaymsg "output * dpms on"' \
    timeout 900 'systemctl suspend' \
    before-sleep 'swaylock -f'

# Window management
bindsym $mod+Return       exec $term
bindsym $mod+space        exec $menu
bindsym $mod+e            exec $filemanager
bindsym $mod+q            kill
bindsym $mod+Shift+e      exit
bindsym $mod+v            floating toggle
bindsym $mod+l            exec $lockcmd
bindsym $mod+f            fullscreen toggle

# Focus
bindsym $mod+Left         focus left
bindsym $mod+Right        focus right
bindsym $mod+Up           focus up
bindsym $mod+Down         focus down

# Workspaces
bindsym $mod+1            workspace number 1
bindsym $mod+2            workspace number 2
bindsym $mod+3            workspace number 3
bindsym $mod+4            workspace number 4
bindsym $mod+5            workspace number 5
bindsym $mod+6            workspace number 6
bindsym $mod+7            workspace number 7
bindsym $mod+8            workspace number 8
bindsym $mod+9            workspace number 9

bindsym $mod+Shift+1      move container to workspace number 1
bindsym $mod+Shift+2      move container to workspace number 2
bindsym $mod+Shift+3      move container to workspace number 3
bindsym $mod+Shift+4      move container to workspace number 4
bindsym $mod+Shift+5      move container to workspace number 5
bindsym $mod+Shift+6      move container to workspace number 6
bindsym $mod+Shift+7      move container to workspace number 7
bindsym $mod+Shift+8      move container to workspace number 8
bindsym $mod+Shift+9      move container to workspace number 9

# Screenshots
bindsym Print             exec grim - | wl-copy
bindsym Shift+Print       exec slurp | grim -g - - | wl-copy

# Brightness + volume (XF86 keys on laptops)
bindsym --locked XF86MonBrightnessUp   exec brightnessctl s 10%+
bindsym --locked XF86MonBrightnessDown exec brightnessctl s 10%-
bindsym --locked XF86AudioRaiseVolume  exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bindsym --locked XF86AudioLowerVolume  exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindsym --locked XF86AudioMute         exec wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle
bindsym --locked XF86AudioMicMute      exec wpctl set-mute   @DEFAULT_AUDIO_SOURCE@ toggle

# Media keys (MPRIS via playerctl)
bindsym --locked XF86AudioPlay         exec playerctl play-pause
bindsym --locked XF86AudioNext         exec playerctl next
bindsym --locked XF86AudioPrev         exec playerctl previous

# Floating drag/resize with Super + mouse
floating_modifier $mod normal

# Cheatsheet: $mod+F1 pops up the keybinding reference in a foot+less
# window (~/.config/sway/cheatsheet.md). Helix-style "what binds do I
# have again?" without having to re-read the config.
bindsym $mod+F1 exec foot --title cheatsheet -e less ~/.config/sway/cheatsheet.md

# Interactive binding picker: $mod+slash (think vim's / for find) pops
# a fuzzel --dmenu over every bindsym in the live sway config, with
# `$mod`/`$term`/etc. expanded. Type-to-filter to find the binding
# you want; selection is informational (just shows it). Selected
# rows close the picker without firing anything -- press the actual
# combo afterwards.
bindsym $mod+slash exec nosi-keys
EOF

# ---- nosi backdrop --------------------------------------------------
# Render the nosi banner to a desktop wallpaper and point sway's `output bg`
# at it. The Catppuccin wordmark card is scaled + centered on a darker crust
# field, and rsvg-convert (librsvg) rasterises it to a 4K PNG. The sway config
# above ships a solid-color bg; we only rewrite that line to the PNG on a
# successful render, so a render failure degrades to the solid Catppuccin base
# rather than a black screen. The JetBrainsMono Nerd Font installed above (or
# any monospace fallback) carries the block-drawing glyphs the wordmark uses.
install -d -m 0755 /usr/share/backgrounds/nosi
cat > /usr/share/backgrounds/nosi/nosi.svg <<'BGSVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080" font-family="ui-monospace, 'JetBrains Mono', Menlo, Monaco, Consolas, 'Courier New', monospace">
  <rect width="1920" height="1080" fill="#11111b"/>
  <g transform="translate(570,295) scale(2.5)">
    <rect x="0" y="0" width="312" height="196" rx="14" fill="#1e1e2e"/>
    <rect x="0.75" y="0.75" width="310.5" height="194.5" rx="13.25" fill="none" stroke="#b4befe" stroke-opacity="0.12" stroke-width="1.5"/>
    <g xml:space="preserve" font-size="16" font-weight="700" text-anchor="middle">
      <text x="156" y="40" fill="#cba6f7">███╗   ██╗ ██████╗ ███████╗██╗</text>
      <text x="156" y="59" fill="#b4befe">████╗  ██║██╔═══██╗██╔════╝██║</text>
      <text x="156" y="78" fill="#89b4fa">██╔██╗ ██║██║   ██║███████╗██║</text>
      <text x="156" y="97" fill="#74c7ec">██║╚██╗██║██║   ██║╚════██║██║</text>
      <text x="156" y="116" fill="#89dceb">██║ ╚████║╚██████╔╝███████║██║</text>
      <text x="156" y="135" fill="#94e2d5">╚═╝  ╚═══╝ ╚═════╝ ╚══════╝╚═╝</text>
    </g>
    <text x="156" y="170" font-size="13" font-style="italic" fill="#fab387" text-anchor="middle">Nic(h)e Operating System Images</text>
  </g>
</svg>
BGSVG
if command -v rsvg-convert >/dev/null 2>&1 \
    && rsvg-convert -w 3840 -h 2160 /usr/share/backgrounds/nosi/nosi.svg \
        -o /usr/share/backgrounds/nosi/nosi.png 2>/dev/null; then
    sed -i 's|^output \* bg #1e1e2e solid_color$|output * bg /usr/share/backgrounds/nosi/nosi.png fill|' \
        /etc/skel/.config/sway/config
    nosi_info "backdrop rendered (/usr/share/backgrounds/nosi/nosi.png)"
else
    nosi_warn "rsvg-convert unavailable or failed; keeping the solid Catppuccin bg"
fi

# ---- nosi-keys: interactive binding picker -------------------------
# A small wrapper that pipes the operator's sway `bindsym` lines
# through fuzzel --dmenu, with `set $foo` substitutions resolved.
# Helix-style discoverability: type "screenshot" to find the Print
# binding without reading the cheatsheet end-to-end. Installed
# system-wide at /usr/local/bin/nosi-keys.
cat > /usr/local/bin/nosi-keys <<'EOF'
#!/usr/bin/env bash
# nosi-keys: fuzzel-dmenu over the operator's sway bindings.
set -euo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}/sway/config"
[ -r "$CFG" ] || {
    notify-send "nosi-keys" "Cannot read $CFG" 2>/dev/null \
        || echo "nosi-keys: cannot read $CFG" >&2
    exit 1
}

awk '
# Capture `set $var value` definitions for later expansion.
$1 == "set" && substr($2, 1, 1) == "$" {
    name = substr($2, 2)
    val  = $0
    sub(/^set[[:space:]]+\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]+/, "", val)
    vars[name] = val
    next
}
# Format every bindsym line as "key : action", with variable expansion.
$1 == "bindsym" {
    line = $0
    # Strip the leading bindsym and any --flag modifiers (--locked, etc.)
    sub(/^bindsym[[:space:]]+(--[a-zA-Z-]+[[:space:]]+)*/, "", line)
    sp = index(line, " ")
    if (sp == 0) next
    key    = substr(line, 1, sp - 1)
    action = substr(line, sp + 1)
    # Expand $foo references.
    for (k in vars) {
        gsub("\\$" k, vars[k], key)
        gsub("\\$" k, vars[k], action)
    }
    # Drop the meta bind that launches us (avoid recursion suggestion).
    if (action ~ /nosi-keys/) next
    printf "%-30s : %s\n", key, action
}
' "$CFG" | fuzzel --dmenu --lines 15 --width 80 --prompt 'binding > ' >/dev/null || true
EOF
chmod 0755 /usr/local/bin/nosi-keys

# ---- nosi-autoscale: conventional HiDPI output scaling -------------
# sway has no built-in DPI awareness -- every output defaults to scale
# 1, so a 4K panel renders the bar + dialogs microscopically. Pick the
# conventional desktop scale from each output's resolution (what
# GNOME/KDE/macOS do by default): 4K -> 200%, QHD -> 150%, else 100%.
# Run at sway startup (exec nosi-autoscale); re-run by hand after
# hotplugging a different-DPI display. Fully best-effort: a missing
# swaymsg/jq or a parse hiccup is a silent no-op, never a broken login.
cat > /usr/local/bin/nosi-autoscale <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command -v swaymsg >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

swaymsg -t get_outputs -r \
    | jq -r '.[] | "\(.name)\t\(.current_mode.width // 0)"' \
    | while IFS=$'\t' read -r name width; do
        if   [ "${width:-0}" -ge 3840 ]; then scale=2
        elif [ "${width:-0}" -ge 2560 ]; then scale=1.5
        else                                   scale=1
        fi
        swaymsg output "$name" scale "$scale" >/dev/null 2>&1 || true
    done
EOF
chmod 0755 /usr/local/bin/nosi-autoscale

# ---- nosi-waybar: hide the battery module on machines with no battery ----
# waybar's built-in battery module renders an empty pill on a desktop / NUC
# that has no battery. Rather than fork the config per shape (one image boots
# on both laptops and desktops), this wrapper drops the "battery" entry from
# modules-right at launch when /sys/class/power_supply has no BAT*, and runs
# waybar unchanged on laptops. Exec'd from sway in place of `waybar`.
cat > /usr/local/bin/nosi-waybar <<'EOF'
#!/bin/sh
# Launch waybar, dropping the battery module when the machine has no battery.
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/config"
if [ ! -f "$cfg" ] || ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
    exec waybar
fi
# No battery: serve a copy of the config with the "battery", line removed.
tmp="${XDG_RUNTIME_DIR:-/tmp}/nosi-waybar-config"
sed '/^[[:space:]]*"battery",[[:space:]]*$/d' "$cfg" > "$tmp"
exec waybar -c "$tmp"
EOF
chmod 0755 /usr/local/bin/nosi-waybar

# ---- Sway cheatsheet -----------------------------------------------
# Plain markdown -- less doesn't render the syntax but the # / ** /
# tables read fine as text. Keep in sync with the bindings above; the
# binding-to-doc drift cost is real but the alternative (parsing the
# live sway config) is more code than the table itself.
cat > /etc/skel/.config/sway/cheatsheet.md <<'EOF'
# nosi Sway cheatsheet

Press `q` to close this window.

`Mod` = `Super` (the Windows / command key).

## Windows

| Combo            | Action                          |
|------------------|---------------------------------|
| Mod + Return     | Open terminal (foot)            |
| Mod + Space      | App launcher (fuzzel)           |
| Mod + E          | File manager (thunar)           |
| Mod + Q          | Close focused window            |
| Mod + V          | Toggle floating                 |
| Mod + F          | Toggle fullscreen               |
| Mod + Arrows     | Move focus                      |
| Mod + drag       | Move floating window with mouse |
| Mod + Shift + E  | Exit sway (logs you out)        |

## Workspaces

| Combo                | Action                       |
|----------------------|------------------------------|
| Mod + 1..9           | Switch to workspace N        |
| Mod + Shift + 1..9   | Move focused window to N     |

## Screen

| Combo            | Action                              |
|------------------|-------------------------------------|
| Mod + L          | Lock screen (swaylock)              |
| Print            | Screenshot whole screen -> clipboard|
| Shift + Print    | Screenshot region -> clipboard      |

## Hardware keys

| Combo                  | Action                       |
|------------------------|------------------------------|
| XF86MonBrightnessUp/Down | Brightness +/- 10%        |
| XF86AudioRaise/LowerVolume | Volume +/- 5%           |
| XF86AudioMute / MicMute  | Toggle sink / source mute |
| XF86AudioPlay/Next/Prev  | MPRIS (playerctl)         |

## Help

| Combo            | Action                                                         |
|------------------|----------------------------------------------------------------|
| Mod + F1         | Show this cheatsheet (less)                                    |
| Mod + /          | Interactive binding picker (fuzzel; type to filter, Esc close) |

## Waybar interactions

| Bar element       | Click             | Right-click           | Scroll        |
|-------------------|-------------------|-----------------------|---------------|
| Workspace number  | Switch to it      |                       |               |
| Audio (volume)    | Toggle mute       | Open pavucontrol      | +/- 5%        |
| Network           | Open nmtui (foot) | Open nm-connection-editor |           |
| Power profile     | Cycle profile     |                       |               |
| Idle inhibitor    | Toggle inhibit    |                       |               |
| Clock             | Toggle format     | Mode (calendar nav)   | Shift months  |

## After a re-bake

Edit `~/.config/sway/config` to add bindings; this cheatsheet does
NOT auto-update. The next nosi re-bake leaves your live config alone
but refreshes `/etc/skel/.config/sway/`, so the canonical reference is
the one shipped at `/etc/skel/.config/sway/cheatsheet.md`.
EOF

# ---- swaylock config -----------------------------------------------
install -d -m 0755 /etc/skel/.config/swaylock
cat > /etc/skel/.config/swaylock/config <<'EOF'
ignore-empty-password
color=151515
font=JetBrainsMono Nerd Font
indicator-radius=100
indicator-thickness=10
EOF

# ---- Waybar ---------------------------------------------------------
install -d -m 0755 /etc/skel/.config/waybar
cat > /etc/skel/.config/waybar/config <<'EOF'
{
    "layer":    "top",
    "position": "top",
    "height":   30,
    "spacing":  6,
    "margin-top":    6,
    "margin-left":   12,
    "margin-right":  12,
    "modules-left":   ["sway/workspaces", "sway/mode"],
    "modules-center": [],
    "modules-right":  [
        "idle_inhibitor",
        "custom/power-profile",
        "pulseaudio",
        "network",
        "battery",
        "tray",
        "clock"
    ],

    "sway/workspaces": {
        "format":            "{name}",
        "disable-scroll":    false,
        "all-outputs":       true,
        "on-click":          "activate"
    },
    "sway/mode": {
        "format": "<span style=\"italic\">{}</span>"
    },
    "sway/window": {
        "max-length": 60,
        "tooltip":    false
    },

    "idle_inhibitor": {
        "format": "{icon}",
        "format-icons": {
            "activated":   "",
            "deactivated": ""
        },
        "tooltip-format-activated":   "idle inhibit ON  (presentation mode)",
        "tooltip-format-deactivated": "idle inhibit OFF (normal idle/lock/suspend)"
    },

    "custom/power-profile": {
        "format":      "{} {icon}",
        "exec":        "powerprofilesctl get",
        "exec-on-event": true,
        "return-type": "",
        "interval":    10,
        "format-icons": {
            "performance": "",
            "balanced":    "",
            "power-saver": ""
        },
        "on-click": "powerprofilesctl set $(powerprofilesctl get | awk '/performance/{print \"power-saver\"; exit} /power-saver/{print \"balanced\"; exit} /balanced/{print \"performance\"; exit}')",
        "tooltip-format": "power-profiles-daemon\nclick to cycle: balanced -> performance -> power-saver"
    },

    "pulseaudio": {
        "format":              "{volume}% {icon}",
        "format-bluetooth":    "{volume}% {icon}",
        "format-muted":        "muted ",
        "format-source":       "{volume}% ",
        "format-source-muted": " ",
        "format-icons": {
            "headphone":  "",
            "hands-free": "",
            "headset":    "",
            "phone":      "",
            "portable":   "",
            "car":        "",
            "default":    ["", "", ""]
        },
        "scroll-step":     5,
        "on-click":        "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
        "on-click-right":  "pavucontrol",
        "tooltip-format":  "{desc}  -  {volume}%"
    },

    "network": {
        "format-wifi":         "{essid} {signalStrength}% ",
        "format-ethernet":     "{ipaddr} ",
        "format-disconnected": "offline ",
        "tooltip-format-wifi":     "{ifname} via {gwaddr}\n{ipaddr}/{cidr}\n{essid} ({signalStrength}%)",
        "tooltip-format-ethernet": "{ifname} via {gwaddr}\n{ipaddr}/{cidr}",
        "tooltip-format-disconnected": "no active network",
        "on-click":       "foot --title nmtui nmtui",
        "on-click-right": "nm-connection-editor"
    },

    "battery": {
        "states": {
            "good":     90,
            "warning":  30,
            "critical": 15
        },
        "format":          "{capacity}% {icon}",
        "format-charging": "{capacity}% ",
        "format-plugged":  "{capacity}% ",
        "format-alt":      "{time} {icon}",
        "format-icons":    ["", "", "", "", ""],
        "tooltip-format":  "{timeTo}, {power}W"
    },

    "clock": {
        "format":         "{:%a %d %b  %H:%M}",
        "format-alt":     "{:%Y-%m-%d %H:%M:%S}",
        "tooltip-format": "<tt><big>{calendar}</big></tt>",
        "calendar": {
            "mode":           "year",
            "mode-mon-col":   3,
            "weeks-pos":      "right",
            "on-scroll":      1,
            "format": {
                "months":     "<span color='#cba6f7'><b>{}</b></span>",
                "days":       "<span color='#c8c8c8'><b>{}</b></span>",
                "weeks":      "<span color='#7f849c'><b>W{}</b></span>",
                "weekdays":   "<span color='#89b4fa'><b>{}</b></span>",
                "today":      "<span color='#f38ba8'><b><u>{}</u></b></span>"
            }
        },
        "actions": {
            "on-click-right": "mode",
            "on-scroll-up":   "shift_up",
            "on-scroll-down": "shift_down"
        }
    },

    "tray": {
        "icon-size": 18,
        "spacing":   10
    }
}
EOF

cat > /etc/skel/.config/waybar/style.css <<'EOF'
/* Catppuccin Mocha, "separated pills": a transparent bar where each module
   is its own rounded, accent-coloured pill with a gap between them, so the
   wallpaper shows through. */

* {
    font-family: "JetBrainsMono Nerd Font", "Symbols Nerd Font", monospace;
    font-size:   13px;
    font-weight: 600;
    border:      none;
    border-radius: 0;
    min-height:  0;
    padding:     0;
    margin:      0;
}

/* Transparent floating bar: pills sit on the wallpaper, not on a solid bar. */
window#waybar {
    background: transparent;
    color:      #cdd6f4;                         /* text */
}

/* Shared pill shape for every module group. Per-module backgrounds below
   override the dark default with an accent. */
#workspaces,
#mode,
#idle_inhibitor,
#custom-power-profile,
#pulseaudio,
#network,
#battery,
#tray,
#clock {
    margin:        6px 3px;
    padding:       2px 14px;
    border-radius: 14px;
    background:    rgba(49, 50, 68, 0.75);       /* surface0, translucent */
    color:         #cdd6f4;
}

/* Workspaces: each its own dark pill; the focused one goes lavender. */
#workspaces { padding: 2px 4px; background: transparent; }
#workspaces button {
    padding:    2px 10px;
    margin:     0 2px;
    color:      #cdd6f4;
    background: rgba(49, 50, 68, 0.75);
    border-radius: 12px;
    transition: background 120ms ease, color 120ms ease;
}
#workspaces button:hover {
    background: rgba(180, 190, 254, 0.25);
    color:      #cdd6f4;
    box-shadow: none;
}
#workspaces button.focused,
#workspaces button.active {
    color:      #1e1e2e;
    background: #b4befe;                         /* lavender */
}
#workspaces button.urgent {
    color:      #1e1e2e;
    background: #f38ba8;                         /* red */
}

#mode { color: #1e1e2e; background: #fab387; }   /* peach */

/* Colourful accent pills (dark text), the cluster on the right. */
#custom-power-profile             { color: #1e1e2e; background: #94e2d5; }   /* teal */
#pulseaudio                       { color: #1e1e2e; background: #cba6f7; }   /* mauve */
#pulseaudio.muted                 { color: #6c7086; background: rgba(49, 50, 68, 0.75); }
#network                          { color: #1e1e2e; background: #89b4fa; }   /* blue */
#network.disconnected             { color: #f38ba8; background: rgba(49, 50, 68, 0.75); }

#battery,
#battery.charging,
#battery.plugged                  { color: #1e1e2e; background: #a6e3a1; }   /* green */
#battery.warning:not(.charging)   { color: #1e1e2e; background: #fab387; }   /* peach */
#battery.critical:not(.charging)  {
    color: #1e1e2e;
    background: #f38ba8;                         /* red */
    animation: blink 1s steps(2) infinite;
}
@keyframes blink {
    50% { background: rgba(243, 139, 168, 0.45); }
}

#idle_inhibitor              { color: #a6adc8; }
#idle_inhibitor.activated    { color: #1e1e2e; background: #fab387; }

/* Clock: the prominent right-most pill (lavender, like the reference's). */
#clock {
    color:       #1e1e2e;
    background:   #b4befe;                        /* lavender */
    font-weight: 700;
    padding:     2px 16px;
}

#tray > .passive   { -gtk-icon-effect: dim; }
#tray > .needs-attention {
    -gtk-icon-effect: highlight;
    background: rgba(243, 139, 168, 0.30);
}
EOF

# ---- foot -----------------------------------------------------------
# Translucent terminal: alpha < 1.0 lets the wallpaper / other windows
# show through under foot. Sway itself doesn't blur (swayfx, the Sway
# fork with blur effects, is the route for picom-style background blur
# but isn't packaged on F44 mainline). Catppuccin Mocha palette
# matches the waybar styling.
install -d -m 0755 /etc/skel/.config/foot
cat > /etc/skel/.config/foot/foot.ini <<'EOF'
font = JetBrainsMono Nerd Font:size=11
pad  = 8x8
dpi-aware = yes

[colors]
alpha    = 0.90
background = 1e1e2e
foreground = cdd6f4
regular0 = 45475a
regular1 = f38ba8
regular2 = a6e3a1
regular3 = f9e2af
regular4 = 89b4fa
regular5 = f5c2e7
regular6 = 94e2d5
regular7 = bac2de
bright0  = 585b70
bright1  = f38ba8
bright2  = a6e3a1
bright3  = f9e2af
bright4  = 89b4fa
bright5  = f5c2e7
bright6  = 94e2d5
bright7  = a6adc8

[scrollback]
lines = 10000

[mouse]
hide-when-typing = yes
EOF

# ---- fuzzel ---------------------------------------------------------
install -d -m 0755 /etc/skel/.config/fuzzel
cat > /etc/skel/.config/fuzzel/fuzzel.ini <<'EOF'
[main]
font     = JetBrainsMono Nerd Font:size=12
prompt   = "> "
terminal = foot
lines    = 12
width    = 36
horizontal-pad = 16
vertical-pad   = 12
inner-pad      = 8

[border]
width  = 1
radius = 12

[colors]
background     = 1e1e2eee
text           = cdd6f4ff
match          = f9e2afff
selection      = b4befeff
selection-text = 1e1e2eff
selection-match = f9e2afff
border         = b4befeff
EOF

# ---- mako -----------------------------------------------------------
install -d -m 0755 /etc/skel/.config/mako
cat > /etc/skel/.config/mako/config <<'EOF'
font             = JetBrainsMono Nerd Font 10
default-timeout  = 7000
background-color = #1e1e2eee
text-color       = #cdd6f4
border-color     = #b4befe
border-size      = 1
padding          = 12
margin           = 10
border-radius    = 12
EOF

# Skel permissions: world-readable directories so /etc/skel-copied
# state lands sanely; user-writable files only via the owner once
# they're in /home/<user>.
chmod -R u=rwX,go=rX /etc/skel/.config

# /etc/skel is rsync'd into /home/<user> only on useradd; odus's home
# was created earlier by cloud-init's users-module before /etc/skel
# had these files. Mirror them in directly so odus boots into a
# usable desktop on first flash. cp -n preserves operator-tweaked
# files across an apply.sh re-run.
if id -u odus >/dev/null 2>&1; then
    install -d -m 0700 -o odus -g odus /home/odus/.config
    # The `sway` entry below also pulls cheatsheet.md (it lives
    # under /etc/skel/.config/sway/ alongside the sway config).
    for sub in sway swaylock waybar foot fuzzel mako; do
        if [ ! -d /home/odus/.config/$sub ]; then
            cp -r /etc/skel/.config/$sub /home/odus/.config/
            chown -R odus:odus /home/odus/.config/$sub
        fi
    done
fi

# ---- enable greetd + graphical target ------------------------------
nosi_info "enabling greetd.service + graphical.target"
systemctl enable greetd.service
systemctl set-default graphical.target

# Note: the greeter runs on vt7 (see the greetd config above), away from
# the foreground-VT kernel/systemd console, so getty@tty1 is left alone
# and tty1 keeps its normal console + login. greetd.service already
# Conflicts=getty@tty7, so the greeter VT has no competing getty.

# ---- enable CUPS + Avahi for printing ------------------------------
# cups.socket starts CUPS on first print attempt (lazy activation, no
# always-on daemon). avahi-daemon enables mDNS so network printers
# advertise themselves on the local link; modern IPP-Everywhere /
# AirPrint discovery flows through this.
nosi_info "enabling cups.socket + avahi-daemon.service"
systemctl enable cups.socket avahi-daemon.service

# ---- unmask polkit (26-daemon-prune masked it on the headless base) -
# The headless prune masks polkit.service (nothing on a headless box
# needs an interactive authorization agent). The desktop does: lxpolkit
# and the xdg-desktop-portals authenticate privileged actions (network,
# mount, power, printer admin) through org.freedesktop.PolicyKit1. Left
# masked, lxpolkit pops "Unit polkit.service is masked" on every login.
# polkit is D-Bus activated, so unmasking is enough -- it starts on
# demand; no explicit enable (the unit is static).
nosi_info "unmasking polkit.service (desktop needs the authorization agent)"
systemctl unmask polkit.service

# ---- Fedora: SELinux relabel on first boot --------------------------
# The desktop derive installs its packages in a chroot (derive_pack), where
# SELinux is not running. The new files (sway, greetd, the rest of the stack)
# land with wrong or missing labels, and greetd's policy module even fails to
# load in the chroot. On the flashed image's first boot SELinux is enforcing,
# so confined services started against those mislabeled files fail: sshd and
# power-profiles-daemon were both observed "Failed to start". The headless base
# is fine because a real boot labels it; only the chrooted derive is affected.
# Schedule a full relabel on the first boot: selinux-autorelabel.service
# consumes /.autorelabel, relabels the filesystem, and reboots once, after
# which every file carries its correct context and the services come up.
# dnf/Fedora only; apt desktops have no SELinux to relabel.
if [ "${NOSI_PKGMGR:-}" = dnf ]; then
    nosi_info "desktop (fedora): scheduling a first-boot SELinux autorelabel"
    : > /.autorelabel
fi

nosi_info "step 50-desktop-stack done"
