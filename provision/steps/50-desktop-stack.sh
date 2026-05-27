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
#
# The configs target a CLI-heavy operator's muscle memory:
#
#   Super + Return  foot
#   Super + Space   fuzzel (app launcher)
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
# Launch tuigreet on vt1, default to sway. --remember +
# --remember-user-session save the chosen user + session command to
# /var/cache/greetd/state.toml so the operator's last selection
# carries across reboots. --asterisks shows password masking instead
# of nothing. Greeting line keeps it on-brand.
install -d -m 0755 /etc/greetd
cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-user-session --asterisks --greeting 'nosi' --cmd sway"
user = "greeter"
EOF
chmod 0644 /etc/greetd/config.toml

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

# Output: autodetect; sway handles hotplug
output * bg #151515 solid_color

# Input
input * {
    xkb_layout us
    natural_scroll enabled
    tap enabled
}

# Gaps + borders
gaps inner 4
gaps outer 8
default_border pixel 2

# Autostart
exec waybar
exec mako
exec /usr/libexec/polkit-gnome-authentication-agent-1
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
    "layer":   "top",
    "position": "top",
    "height":   28,
    "spacing":  8,
    "modules-left":   ["sway/workspaces", "sway/window"],
    "modules-center": ["clock"],
    "modules-right":  ["pulseaudio", "network", "battery", "tray"],

    "sway/workspaces": {
        "format":   "{name}",
        "on-click": "activate"
    },
    "sway/window": {
        "max-length": 60
    },
    "clock": {
        "format":         "{:%a %d %b %H:%M}",
        "tooltip-format": "<big>{:%Y-%m-%d %H:%M:%S}</big>"
    },
    "pulseaudio": {
        "format":       "{volume}% {icon}",
        "format-muted": "muted",
        "format-icons": {"default": ["", "", ""]},
        "on-click":     "pavucontrol"
    },
    "network": {
        "format-wifi":         "{essid} {signalStrength}%",
        "format-ethernet":     "eth",
        "format-disconnected": "off",
        "tooltip-format":      "{ifname}: {ipaddr}/{cidr}"
    },
    "battery": {
        "format":       "{capacity}% {icon}",
        "format-icons": ["", "", "", "", ""],
        "states": {
            "warning":  30,
            "critical": 15
        }
    },
    "tray": {
        "spacing": 8
    }
}
EOF

cat > /etc/skel/.config/waybar/style.css <<'EOF'
* {
    font-family: "JetBrainsMono Nerd Font", monospace;
    font-size:   12px;
    border:      none;
    border-radius: 0;
    min-height:  0;
}

window#waybar {
    background-color: rgba(15, 15, 15, 0.9);
    color:            #c8c8c8;
}

#workspaces button {
    padding:    0 6px;
    color:      #707070;
    background: transparent;
}

#workspaces button.active {
    color:      #ffffff;
    background: #2a2a2a;
}

#clock, #pulseaudio, #network, #battery, #tray, #window {
    padding: 0 8px;
}

#battery.warning  { color: #f0c674; }
#battery.critical { color: #cc6666; }
EOF

# ---- foot -----------------------------------------------------------
install -d -m 0755 /etc/skel/.config/foot
cat > /etc/skel/.config/foot/foot.ini <<'EOF'
font = JetBrainsMono Nerd Font:size=11

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

[colors]
background     = 151515ee
text           = c8c8c8ff
selection      = 2a2a2aff
selection-text = ffffffff
border         = 606060ff
EOF

# ---- mako -----------------------------------------------------------
install -d -m 0755 /etc/skel/.config/mako
cat > /etc/skel/.config/mako/config <<'EOF'
font             = JetBrainsMono Nerd Font 10
default-timeout  = 7000
background-color = #151515ee
text-color       = #c8c8c8
border-color     = #606060
border-size      = 1
padding          = 10
margin           = 8
border-radius    = 4
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

nosi_info "step 50-desktop-stack done"
