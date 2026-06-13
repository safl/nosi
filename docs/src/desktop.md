# Desktop shape

The `desktop` variants ship a complete, pre-configured **Sway** (Wayland
tiling) desktop on top of the same toolset the headless images carry. They
boot straight into a graphical greeter and, on login, into a usable desktop
— no `startx`, no blank `sway`, no dotfile hunt.

Three variants build the desktop shape:

- `debian-13-desktop` (x86_64)
- `fedora-44-desktop` (x86_64)
- `rpios-13-desktop` (arm64, Raspberry Pi 4 / CM4 / Pi 5 / CM5)

All three share one provisioning step, so the experience — keybindings,
theming, the discovery tooling below — is identical across them; only the
underlying package names differ.

## What's in it

The canonical wlroots/Sway stack, pre-wired:

| Role | Tool |
|------|------|
| Compositor (tiling WM) | **sway** |
| Greeter | **greetd** + **tuigreet** → sway |
| Terminal | **foot** |
| Status bar | **waybar** |
| App launcher | **fuzzel** |
| Notifications | **mako** |
| Lock / idle / wallpaper | **swaylock** / **swayidle** / **swaybg** |
| Screenshots | **grim** + **slurp** |
| Clipboard | **wl-clipboard** + **cliphist** |
| Desktop portal | **xdg-desktop-portal-wlr** |
| Polkit agent | **lxpolkit** |
| File manager | **thunar** (+ gvfs, thunar-volman, tumbler) |
| Browser | **firefox** / firefox-esr |
| Audio | **pipewire** + wireplumber + pavucontrol |
| Bluetooth | **bluez** |
| Power / backlight / media | power-profiles-daemon, brightnessctl, playerctl |
| Network applet | **nm-applet** |
| Printing | **cups** + **avahi** (lazy-activated) |
| GUI git | meld, gitk, git-gui |
| Fonts | Noto + **JetBrainsMono Nerd Font** |

The look is **Catppuccin Mocha** across waybar, foot, fuzzel, mako and the
lock screen, with the nosi wordmark rendered to the wallpaper.

## First login

greetd launches **tuigreet** on the first virtual terminal: a `nosi`
greeting, a clock, and an asterisk-masked password field. Log in with the
default operator account:

```
odus / odus.321
```

and you land in Sway. The default password is not force-rotated; rotate it
with `passwd`. See [](credentials.md) for the full account / SSH model.

## Keybindings

`Mod` is the **Super** (Windows / Command) key.

### Windows

| Combo | Action |
|-------|--------|
| `Mod + Return` | Open terminal (foot) |
| `Mod + Space` | App launcher (fuzzel) |
| `Mod + E` | File manager (thunar) |
| `Mod + Q` | Close focused window |
| `Mod + V` | Toggle floating |
| `Mod + F` | Toggle fullscreen |
| `Mod + Arrows` | Move focus |
| `Mod + drag` | Move a floating window with the mouse |
| `Mod + Shift + E` | Exit Sway (logs you out) |

### Workspaces

| Combo | Action |
|-------|--------|
| `Mod + 1..9` | Switch to workspace N |
| `Mod + Shift + 1..9` | Move focused window to workspace N |

### Screen

| Combo | Action |
|-------|--------|
| `Mod + L` | Lock screen (swaylock) |
| `Print` | Screenshot whole screen → clipboard |
| `Shift + Print` | Screenshot a region → clipboard |

### Hardware keys

The `XF86` brightness / volume / media keys are bound (brightnessctl,
`wpctl`, and playerctl for MPRIS). swayidle locks after 5 min, blanks the
screen at 10, and suspends at 15.

## Finding your way around

Two discovery aids, because a tiling desktop is only as good as your memory
of its bindings:

- **`Mod + /` → `nosi-keys`** — an interactive, *always-accurate* binding
  picker. It parses your **live** `~/.config/sway/config`, expands the
  `$term` / `$menu` / `$mod` variables to their real values, and feeds every
  binding to `fuzzel --dmenu` as `key : action`. Type `screenshot` to find
  `Print`, type `lock` to find `Mod + L`. Because it reads the running
  config rather than a hand-kept list, it never drifts — edit a binding and
  the picker reflects it immediately. Selecting a row just closes the picker
  (it's informational; you then press the real combo).

- **`Mod + F1` → cheatsheet** — a formatted reference (`foot` + `less`) at
  `~/.config/sway/cheatsheet.md`, handy for a printable/scrollable overview.

The **waybar** modules are interactive too: click the audio module to
mute / right-click for pavucontrol, click network for `nmtui` /
right-click for the connection editor, click the power-profile module to
cycle balanced → performance → power-saver, click the clock to toggle a
calendar.

## Customizing

nosi seeds opinionated configs but never owns your copy of them:

- Configs live under `~/.config/` — `sway/`, `waybar/`, `foot/`, `fuzzel/`,
  `mako/`, `swaylock/`. They are copied from `/etc/skel` on first login (and
  mirrored into the baked `odus` home), so they are **yours** to edit in
  place.
- A nosi re-apply (`apply.sh <variant>-desktop`) refreshes `/etc/skel` but
  leaves your live `~/.config` files alone (`cp -n`), so personalisation
  survives a re-bake.

Common tweaks:

```bash
# Rebind / add a binding: edit the config, reload Sway in place.
$EDITOR ~/.config/sway/config
swaymsg reload                     # nosi-keys reflects the change immediately

# Change the wallpaper.
swaymsg 'output * bg ~/Pictures/wall.png fill'
# (persist it by editing the `output * bg ...` line in the sway config)
```

The `greeter` is `tuigreet --cmd sway`; swap the session command or greeter
in `/etc/greetd/config.toml` if you prefer a different default session.

## Notes

- On the Raspberry Pi (`rpios-13-desktop`) the desktop runs on the V3D KMS
  driver that Raspberry Pi OS already ships (`vc4-kms-v3d`); no extra GPU
  setup is needed on Pi 4 / CM4 / Pi 5 / CM5.
- The desktop shape sets `graphical.target` as the default boot target and
  enables `greetd`, so a flashed box comes up at the greeter with no further
  configuration.
