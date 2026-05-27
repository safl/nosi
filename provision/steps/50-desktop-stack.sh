#!/usr/bin/env bash
# nosi/provision/steps/50-desktop-stack.sh
#
# desktop shape only. Configures the Hyprland-based desktop stack:
#
#   * greetd + tuigreet as the system display manager, defaulting to
#     a Hyprland session
#   * opinionated default configs for Hyprland / hyprlock / hypridle
#     / waybar / foot / fuzzel / mako under /etc/skel/.config/
#   * mirror of those defaults into /home/odus/.config/ so the baked
#     operator account boots into a usable desktop on first login
#   * graphical.target as the default systemd target
#
# The configs target a CLI-heavy operator's muscle memory:
#
#   Super + Return  foot
#   Super + Space   fuzzel (app launcher)
#   Super + L       hyprlock (screen lock)
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
# Launch tuigreet on vt1, default to Hyprland. --remember +
# --remember-user-session save the chosen user + session command to
# /var/cache/greetd/state.toml so the operator's last selection
# carries across reboots. --asterisks shows password masking instead
# of nothing. Greeting line keeps it on-brand.
install -d -m 0755 /etc/greetd
cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-user-session --asterisks --greeting 'nosi' --cmd Hyprland"
user = "greeter"
EOF
chmod 0644 /etc/greetd/config.toml

# ---- Hyprland config ------------------------------------------------
install -d -m 0755 /etc/skel/.config/hypr
cat > /etc/skel/.config/hypr/hyprland.conf <<'EOF'
# nosi default Hyprland config. Copied from /etc/skel/.config/hypr/
# on first login; personalise in place, nosi never overwrites it.
# Reference: https://wiki.hyprland.org/Configuring/

monitor = , preferred, auto, 1

$mod = SUPER
$terminal = foot
$launcher = fuzzel
$lockcmd  = hyprlock

# Autostart
exec-once = waybar
exec-once = mako
exec-once = hypridle
exec-once = hyprpolkitagent
exec-once = wl-paste --watch cliphist store

# Input
input {
    kb_layout = us
    follow_mouse = 1
    touchpad {
        natural_scroll = yes
        tap-to-click   = yes
    }
}

general {
    gaps_in     = 4
    gaps_out    = 8
    border_size = 2
    layout      = dwindle
}

decoration {
    rounding = 4
}

animations {
    enabled = true
}

# Window management
bind = $mod,       Return, exec, $terminal
bind = $mod,       Space,  exec, $launcher
bind = $mod,       Q,      killactive
bind = $mod SHIFT, E,      exit
bind = $mod,       V,      togglefloating
bind = $mod,       L,      exec, $lockcmd
bind = $mod,       F,      fullscreen, 0

# Focus
bind = $mod, left,  movefocus, l
bind = $mod, right, movefocus, r
bind = $mod, up,    movefocus, u
bind = $mod, down,  movefocus, d

# Workspaces
bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod, 6, workspace, 6
bind = $mod, 7, workspace, 7
bind = $mod, 8, workspace, 8
bind = $mod, 9, workspace, 9

bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5
bind = $mod SHIFT, 6, movetoworkspace, 6
bind = $mod SHIFT, 7, movetoworkspace, 7
bind = $mod SHIFT, 8, movetoworkspace, 8
bind = $mod SHIFT, 9, movetoworkspace, 9

# Screenshots
bind = ,      Print, exec, grim - | wl-copy
bind = SHIFT, Print, exec, slurp | grim -g - - | wl-copy

# Brightness + volume (XF86 keys on laptops). bindel = bindable
# event-triggered + locked-state-allowed (keys work with screen locked).
bindel = , XF86MonBrightnessUp,   exec, brightnessctl s 10%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl s 10%-
bindel = , XF86AudioRaiseVolume,  exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume,  exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindel = , XF86AudioMute,         exec, wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle
bindel = , XF86AudioMicMute,      exec, wpctl set-mute   @DEFAULT_AUDIO_SOURCE@ toggle

# Media keys (MPRIS via playerctl)
bindl = , XF86AudioPlay, exec, playerctl play-pause
bindl = , XF86AudioNext, exec, playerctl next
bindl = , XF86AudioPrev, exec, playerctl previous

# Window drag with mouse
bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow
EOF

# ---- Hyprlock -------------------------------------------------------
cat > /etc/skel/.config/hypr/hyprlock.conf <<'EOF'
background {
    color = rgba(15, 15, 15, 1.0)
}

input-field {
    size            = 250, 50
    position        = 0, 0
    halign          = center
    valign          = center
    placeholder_text = password
    hide_input      = false
    fade_on_empty   = false
}

label {
    text       = cmd[update:1000] echo "$(date +'%H:%M:%S')"
    font_size  = 32
    position   = 0, 80
    halign     = center
    valign     = center
}
EOF

# ---- Hypridle -------------------------------------------------------
cat > /etc/skel/.config/hypr/hypridle.conf <<'EOF'
general {
    lock_cmd         = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd  = hyprctl dispatch dpms on
}

listener {
    timeout    = 300                                    # 5 min
    on-timeout = loginctl lock-session
}

listener {
    timeout    = 600                                    # 10 min
    on-timeout = hyprctl dispatch dpms off
    on-resume  = hyprctl dispatch dpms on
}

listener {
    timeout    = 900                                    # 15 min
    on-timeout = systemctl suspend
}
EOF

# ---- Waybar ---------------------------------------------------------
install -d -m 0755 /etc/skel/.config/waybar
cat > /etc/skel/.config/waybar/config <<'EOF'
{
    "layer":   "top",
    "position": "top",
    "height":   28,
    "spacing":  8,
    "modules-left":   ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right":  ["pulseaudio", "network", "battery", "tray"],

    "hyprland/workspaces": {
        "format":   "{name}",
        "on-click": "activate"
    },
    "hyprland/window": {
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
    for sub in hypr waybar foot fuzzel mako; do
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
