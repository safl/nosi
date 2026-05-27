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
titlebar_padding 0

# Focus follows the click, not the mouse motion.
focus_follows_mouse no

# Autostart
exec nm-applet --indicator
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

# Cheatsheet: $mod+F1 pops up the keybinding reference in a foot+less
# window (~/.config/sway/cheatsheet.md). Helix-style "what binds do I
# have again?" without having to re-read the config.
bindsym $mod+F1 exec foot --title cheatsheet -e less ~/.config/sway/cheatsheet.md
EOF

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

| Combo            | Action                       |
|------------------|------------------------------|
| Mod + F1         | Show this cheatsheet         |

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
    "modules-left":   ["sway/workspaces", "sway/mode", "sway/window"],
    "modules-center": ["clock"],
    "modules-right":  [
        "idle_inhibitor",
        "custom/power-profile",
        "pulseaudio",
        "network",
        "battery",
        "tray"
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
/* Catppuccin Mocha-ish palette, kept minimal so the bar looks calm
   against most wallpapers. */

* {
    font-family: "JetBrainsMono Nerd Font", "Symbols Nerd Font", monospace;
    font-size:   13px;
    font-weight: 500;
    border:      none;
    border-radius: 0;
    min-height:  0;
    padding:     0;
    margin:      0;
}

window#waybar {
    background-color: rgba(24, 24, 37, 0.88);   /* base */
    color:            #cdd6f4;                  /* text */
    border-radius:    14px;
    border:           1px solid rgba(180, 190, 254, 0.10);
}

#workspaces {
    margin: 0 4px;
}
#workspaces button {
    padding:    2px 12px;
    margin:     4px 2px;
    color:      #6c7086;
    background: transparent;
    border-radius: 12px;
    transition: background 120ms ease, color 120ms ease;
}
#workspaces button:hover {
    background: rgba(180, 190, 254, 0.10);
    color:      #cdd6f4;
    box-shadow: none;
}
#workspaces button.focused,
#workspaces button.active {
    color:      #1e1e2e;
    background: #b4befe;                        /* lavender */
}
#workspaces button.urgent {
    color:      #1e1e2e;
    background: #f38ba8;                        /* red */
}

#window {
    padding: 0 12px;
    color:   #a6adc8;                           /* subtext0 */
    font-weight: 400;
}

#mode {
    padding: 0 12px;
    color:   #1e1e2e;
    background: #fab387;                        /* peach */
    border-radius: 12px;
    margin:  4px 4px;
}

#clock {
    padding: 0 14px;
    color:   #cdd6f4;
    font-weight: 600;
}

#idle_inhibitor,
#custom-power-profile,
#pulseaudio,
#network,
#battery,
#tray {
    padding: 2px 12px;
    margin:  4px 2px;
    border-radius: 12px;
    background: rgba(49, 50, 68, 0.55);          /* surface0 */
    color:      #cdd6f4;
}

#idle_inhibitor.activated         { color: #fab387; background: rgba(250, 179, 135, 0.18); }
#custom-power-profile             { color: #94e2d5; }                  /* teal */
#pulseaudio.muted                 { color: #6c7086; }
#network.disconnected             { color: #f38ba8; }
#battery.charging,
#battery.plugged                  { color: #a6e3a1; }                  /* green */
#battery.warning:not(.charging)   { color: #fab387; }
#battery.critical:not(.charging)  {
    color: #f38ba8;
    background: rgba(243, 139, 168, 0.18);
    animation: blink 1s steps(2) infinite;
}
@keyframes blink {
    50% { background: rgba(243, 139, 168, 0.05); }
}

#tray > .passive   { -gtk-icon-effect: dim; }
#tray > .needs-attention {
    -gtk-icon-effect: highlight;
    background: rgba(243, 139, 168, 0.18);
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

nosi_info "step 50-desktop-stack done"
