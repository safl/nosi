#!/usr/bin/env bash
# nosi/provision/steps/33-serial-console.sh
#
# Put the kernel console (boot messages plus a login prompt) on the first
# serial port so the box is reachable over a server BMC's IPMI
# Serial-over-LAN, and over a plain serial cable. The video console is kept
# as well, so a machine used the normal way still prints to screen.
#
# Three boot stacks, three mechanisms, and this step is the one place that
# knows all three:
#
#   apt/dnf (x86): grub cmdline -> console=tty0 console=ttyS1 console=ttyS0
#                  ttyS0 = COM1, ttyS1 = COM2. Both are wired because server
#                  BMCs disagree on which UART they bridge to IPMI SOL
#                  (Supermicro/Dell/HPE commonly use COM2). The kernel prints
#                  boot messages to every console= device, so both ports see
#                  output; ttyS0 is kept LAST so COM1 stays /dev/console (the
#                  universally present port, which keeps single-UART boards and
#                  the QEMU smoketest on COM1). An unwired port just sits idle.
#   pkg (freebsd): /boot/loader.conf -> console="vidconsole,comconsole"
#                  comconsole = uart0 = COM1 (COM2-only BMCs additionally need
#                  comconsole_port="0x2f8"); getty via /etc/ttys onifconsole.
#   raspberry pi:  /boot/firmware/{cmdline,config}.txt -> console=serial0
#                  the GPIO UART (no BMC on a Pi; read with a USB-TTL cable).
#
# Most x86 cloud bases already ship console=ttyS0 (COM1); this step adds the
# COM2 port and guarantees the full set across every base, rather than assuming
# upstream keeps doing it. It also backs the smoketest's hard assertion.
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
# The Pi boot path has no grub; kernel args live in cmdline.txt and the UART
# clock is pinned in config.txt. rpi_image_build mounts the FAT firmware
# partition at /boot/firmware before running apply.sh, so these files are
# present in the bake chroot. Detect the Pi by that file rather than by arch,
# so a non-Pi arm64 box never half-writes a Pi config.
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

# Everything past here is x86: the Pi returned above and the nosi FreeBSD
# images are x86_64. Guard anyway so a future non-x86 base (where ttyS0 /
# comconsole = uart0 may not be the right device) skips rather than writing a
# config that never applies.
case "$(uname -m)" in
x86_64 | amd64) : ;;
*)
    nosi_info "non-x86 arch ($(uname -m)); skipping (x86 serial console only)"
    exit 0
    ;;
esac

# A serial login prompt comes from serial-getty@<port>. systemd's getty
# generator auto-starts one only on the single primary console, so with two
# serial consoles on the cmdline the secondary port (e.g. the COM2 a BMC
# bridges) would get kernel boot messages but no login. Enable both ports
# explicitly. serial-getty@.service has BindsTo=dev-<port>.device, so the unit
# for a port with no UART (a single-COM board, or no serial at all) stays
# dormant rather than failed; this is the same dependency the generator itself
# uses for the primary console.
enable_serial_gettys() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl enable serial-getty@ttyS0.service serial-getty@ttyS1.service
}

case "$NOSI_PKGMGR" in
apt)
    GRUB=/etc/default/grub
    [ -f "$GRUB" ] || {
        nosi_warn "$GRUB missing; cannot set serial console"
        exit 0
    }

    # Pin the kernel serial console via a grub.d drop-in that grub-mkconfig
    # sources LAST (after /etc/default/grub and every base snippet). Merely
    # appending console= to GRUB_CMDLINE_LINUX is NOT enough: the Debian/Ubuntu
    # cloud bases set a bare `console=ttyS0` (no baud) in
    # GRUB_CMDLINE_LINUX_DEFAULT, which grub emits AFTER GRUB_CMDLINE_LINUX, so
    # that bare token wins as /dev/console and leaves the UART at the kernel
    # default (9600) -- which shows nothing on an IPMI SOL / terminal at 115200.
    # So instead sanitize both assembled cmdline vars (strip every console= the
    # base set) and re-pin the canonical ordered set with an explicit 115200n8
    # at the END of *_DEFAULT, making ttyS0 (COM1) genuinely last =>
    # /dev/console = COM1 @115200, with ttyS1 (COM2) also wired for BMCs that
    # bridge it. Strip serial (ttyS) FIRST so the tty[0-9] strip never eats the
    # `tty` in `ttyS`. Idempotent: the drop-in re-runs on every grub-mkconfig
    # and converges. This is the apt equivalent of the dnf branch's
    # grubby --remove-args/--args canonicalisation below.
    nosi_write_if_changed \
'# Managed by nosi/provision/steps/33-serial-console.sh
# Sourced last by grub-mkconfig. Strip any console= the base set, then pin the
# canonical ordered serial console with an explicit baud so IPMI SOL is
# deterministic (a trailing bare console=ttyS0 would default the UART to 9600).
_nosi_strip="s/console=ttyS[0-9][^ ]*//g; s/console=tty[0-9][^ ]*//g; s/  */ /g; s/^ *//; s/ *$//"
GRUB_CMDLINE_LINUX="$(printf %s "${GRUB_CMDLINE_LINUX:-}" | sed -e "$_nosi_strip")"
GRUB_CMDLINE_LINUX_DEFAULT="$(printf %s "${GRUB_CMDLINE_LINUX_DEFAULT:-}" | sed -e "$_nosi_strip")"
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }console=tty0 console=ttyS1,115200n8 console=ttyS0,115200n8"
unset _nosi_strip
' /etc/default/grub.d/99-nosi-serial-console.cfg 0644
    nosi_info "grub.d drop-in: pinned tty0 + ttyS1 (COM2) + ttyS0 (COM1) @115200n8"
    update-grub
    enable_serial_gettys
    ;;
dnf)
    # grubby appends new --args at the END, so a plain add of console=ttyS1
    # would make it /dev/console. Instead strip any existing tty0/ttyS0/ttyS1
    # console tokens and re-add the canonical ordered set, so ttyS0 (COM1)
    # always trails => /dev/console = COM1. Read the default kernel's args (the
    # tokens are identical across kernels); the update targets ALL kernels.
    cur="$(grubby --info=DEFAULT 2>/dev/null | sed -n 's/^args=//p' | tr -d '"' || true)"
    if printf '%s\n' "$cur" | grep -q 'console=ttyS1'; then
        nosi_info "serial console already on the kernel args"
    else
        rm_args=""
        for tok in $cur; do
            case "$tok" in
            console=tty0 | console=tty1 | console=ttyS0 | console=ttyS0,* | console=ttyS1 | console=ttyS1,*)
                rm_args="${rm_args:+$rm_args }$tok"
                ;;
            esac
        done
        [ -n "$rm_args" ] && grubby --update-kernel=ALL --remove-args="$rm_args"
        grubby --update-kernel=ALL --args="console=tty0 console=ttyS1,115200n8 console=ttyS0,115200n8"
        nosi_info "grubby console args set: tty0 + ttyS1 (COM2) + ttyS0 (COM1)"
    fi
    enable_serial_gettys
    ;;
pkg)
    # FreeBSD: loader.conf is the cmdline equivalent. Dual console with
    # vidconsole FIRST keeps video as the primary console (normal-use output)
    # while comconsole (uart0 = COM1) mirrors to the serial line for IPMI SOL.
    # Rewrite in place: drop any existing console= / comconsole_speed= lines,
    # then append the canonical pair, so a re-run converges to the same file.
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
    # console, now true via loader.conf. Only rewrite the flags field if that
    # line is not already onifconsole.
    TTYS=/etc/ttys
    if [ -f "$TTYS" ] && ! grep -qE '^ttyu0[[:space:]].*onifconsole' "$TTYS"; then
        sed -i '' -E 's|^(ttyu0[[:space:]]+"[^"]*"[[:space:]]+[^[:space:]]+[[:space:]]+).*$|\1onifconsole secure|' "$TTYS"
        nosi_info "ttys: ttyu0 -> onifconsole"
    fi
    ;;
*)
    nosi_info "no serial-console plumbing for pkgmgr=$NOSI_PKGMGR; skipping"
    exit 0
    ;;
esac

nosi_info "step 33-serial-console done"
