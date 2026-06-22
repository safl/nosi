#!/usr/bin/env bash
# nosi/provision/steps/33-serial-console.sh
#
# Put the kernel console (boot messages + a login prompt) on the first
# serial port so the box is reachable over a server BMC's IPMI
# Serial-over-LAN, and over a plain serial cable. The video console is
# kept as well, so a machine used the normal way still prints to screen.
#
# Three boot stacks, three mechanisms -- this step is the one place that
# knows all three:
#
#   apt/dnf (x86): grub cmdline  -> console=tty0 console=ttyS0,115200n8
#                  ttyS0 = COM1, the UART a BMC bridges for IPMI SOL.
#   pkg (freebsd): /boot/loader.conf -> console="vidconsole,comconsole"
#                  comconsole = uart0 = COM1; getty via /etc/ttys onifconsole.
#   raspberry pi:  /boot/firmware/{cmdline,config}.txt -> console=serial0
#                  the GPIO UART (no BMC on a Pi; read with a USB-TTL cable).
#
# Most x86 cloud bases already ship console=ttyS0, so on those this step
# detects it and is a no-op. It exists to GUARANTEE the console across
# every base (and to back the smoketest's hard assertion), not to assume
# upstream keeps doing it.
#
# Idempotent: each branch checks for an existing serial console before
# writing, so a re-run changes nothing. Takes effect on the next boot.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 33-serial-console (pkgmgr=$NOSI_PKGMGR)"

# WSL has no bootloader and no real UART; nothing to wire.
if nosi_is_wsl; then
    nosi_info "WSL detected; skipping (no bootloader, no serial console)"
    exit 0
fi

# ---- Raspberry Pi: firmware partition, not grub ---------------------------
# The Pi boot path has no grub; kernel args live in cmdline.txt and the
# UART clock is pinned in config.txt. rpi_image_build mounts the FAT
# firmware partition at /boot/firmware before running apply.sh, so these
# files are present in the bake chroot. Detect the Pi by that file rather
# than by arch, so a non-Pi arm64 box never half-writes a Pi config.
if [ -f /boot/firmware/cmdline.txt ]; then
    nosi_require_root

    CMDLINE=/boot/firmware/cmdline.txt
    CONFIG=/boot/firmware/config.txt

    # cmdline.txt is a single line; serial0 is the firmware alias for the
    # primary UART (PL011 on Pi 4/5). Raspberry Pi OS Lite already ships
    # console=serial0,115200, so this usually just confirms it.
    if grep -qE 'console=(serial0|ttyAMA0|ttyS0)' "$CMDLINE"; then
        nosi_info "cmdline.txt already has a serial console"
    else
        sed -i '1s|^|console=serial0,115200 |' "$CMDLINE"
        nosi_info "cmdline.txt: added console=serial0,115200"
    fi

    # enable_uart=1 pins the core clock so the UART baud stays stable.
    if [ -f "$CONFIG" ]; then
        if grep -qE '^enable_uart=1([[:space:]]|$)' "$CONFIG"; then
            nosi_info "config.txt already has enable_uart=1"
        elif grep -qE '^enable_uart=' "$CONFIG"; then
            sed -i 's|^enable_uart=.*|enable_uart=1|' "$CONFIG"
            nosi_info "config.txt: set enable_uart=1"
        else
            printf 'enable_uart=1\n' >> "$CONFIG"
            nosi_info "config.txt: appended enable_uart=1"
        fi
    fi

    nosi_info "step 33-serial-console done (raspberry pi)"
    exit 0
fi

nosi_require_root

case "$NOSI_PKGMGR" in
apt | dnf)
    # ttyS0 is an x86 UART and the grub/grubby plumbing below is x86-only.
    # Any non-Pi non-x86 box (none ship today) is left untouched.
    case "$(uname -m)" in
    x86_64 | amd64) : ;;
    *)
        nosi_info "non-x86 arch ($(uname -m)); skipping (serial console is x86 grub here)"
        exit 0
        ;;
    esac

    # Decide what is missing. Look across /etc/default/grub AND the
    # /etc/default/grub.d snippets the cloud images drop their console
    # settings into, so an already-present console=ttyS0 is never
    # duplicated. tty0 keeps the video console; ttyS0 adds COM1.
    GRUB=/etc/default/grub
    has_serial() { grep -rqE 'console=ttyS0' "$GRUB" /etc/default/grub.d 2>/dev/null; }
    has_video() { grep -rqE 'console=tty[01]([,"[:space:]]|$)' "$GRUB" /etc/default/grub.d 2>/dev/null; }
    ;;
pkg)
    : # handled in its own branch below
    ;;
*)
    nosi_info "no serial-console plumbing for pkgmgr=$NOSI_PKGMGR; skipping"
    exit 0
    ;;
esac

case "$NOSI_PKGMGR" in
apt)
    [ -f "$GRUB" ] || {
        nosi_warn "$GRUB missing; cannot set serial console"
        exit 0
    }

    want=""
    has_serial || want="console=ttyS0,115200n8"
    has_video || want="console=tty0${want:+ $want}"

    if [ -z "$want" ]; then
        nosi_info "serial console already on the grub cmdline; nothing to do"
        exit 0
    fi

    if grep -q '^GRUB_CMDLINE_LINUX=' "$GRUB"; then
        sed -i "s/^GRUB_CMDLINE_LINUX=\"\(.*\)\"$/GRUB_CMDLINE_LINUX=\"\1 ${want}\"/" "$GRUB"
    else
        printf '\nGRUB_CMDLINE_LINUX="%s"\n' "$want" >> "$GRUB"
    fi
    nosi_info "grub cmdline += ${want}"
    update-grub
    ;;
dnf)
    cur="$(grubby --info=ALL 2>/dev/null | grep -E '^args=' || true)"
    want=""
    printf '%s\n' "$cur" | grep -q 'console=ttyS0' || want="console=ttyS0,115200n8"
    printf '%s\n' "$cur" | grep -qE 'console=tty[01]([,"[:space:]]|$)' || want="console=tty0${want:+ $want}"

    if [ -z "$want" ]; then
        nosi_info "serial console already on the kernel args; nothing to do"
        exit 0
    fi
    nosi_info "grubby args += ${want}"
    grubby --update-kernel=ALL --args="$want"
    ;;
pkg)
    # FreeBSD: loader.conf is the cmdline equivalent. Dual console with
    # vidconsole FIRST keeps video as the primary console (normal-use
    # output) while comconsole (uart0 = COM1) mirrors to the serial line
    # for IPMI SOL. Rewrite in place: drop any existing console= /
    # comconsole_speed= lines, then append the canonical pair, so a re-run
    # converges to the same file.
    LOADER=/boot/loader.conf
    touch "$LOADER"
    tmp="$(mktemp)"
    grep -vE '^(console|comconsole_speed)=' "$LOADER" > "$tmp" 2>/dev/null || true
    {
        printf 'console="vidconsole,comconsole"\n'
        printf 'comconsole_speed="115200"\n'
    } >> "$tmp"
    cat "$tmp" > "$LOADER"
    rm -f "$tmp"
    nosi_info "loader.conf: console=vidconsole,comconsole @115200"

    # getty on the serial port. The stock FreeBSD /etc/ttys ttyu0 line uses
    # `onifconsole`, which spawns getty exactly when ttyu0 is an active
    # console -- now true via loader.conf. Only rewrite the flags field if
    # that line is not already onifconsole.
    TTYS=/etc/ttys
    if [ -f "$TTYS" ] && ! grep -qE '^ttyu0[[:space:]].*onifconsole' "$TTYS"; then
        sed -i '' -E 's|^(ttyu0[[:space:]]+"[^"]*"[[:space:]]+[^[:space:]]+[[:space:]]+).*$|\1onifconsole secure|' "$TTYS"
        nosi_info "ttys: ttyu0 -> onifconsole"
    fi
    ;;
esac

nosi_info "step 33-serial-console done"
