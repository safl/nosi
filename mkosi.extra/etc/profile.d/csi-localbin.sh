# Add ~/.local/bin to PATH for any interactive shell — system-wide equivalent
# of `pipx ensurepath`, so the default user (odus) and any user created later
# can run pipx-installed tools without first touching their rc files.

if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) : ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
fi
