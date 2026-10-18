#!/usr/bin/env bash
# install.sh — Installs agent-sandbox into your PATH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$SCRIPT_DIR/bin/agent-sandbox"

echo "=== Installing agent-sandbox ==="

# 1. Check for Bubblewrap (bwrap)
if ! command -v bwrap >/dev/null 2>&1; then
  echo "[!] Warning: 'bwrap' (bubblewrap) was not found in your PATH."
  echo "    agent-sandbox requires bubblewrap for profile isolation."
  echo "    Install it using your distribution package manager:"
  echo "      Debian/Ubuntu: sudo apt install bubblewrap"
  echo "      Fedora/RHEL:   sudo dnf install bubblewrap"
  echo "      Arch Linux:    sudo pacman -S bubblewrap"
  echo "      Alpine Linux:  sudo apk add bubblewrap"
  echo ""
fi

# 2. Determine target binary directory
TARGET_DIR=""
if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ]; then
  TARGET_DIR="$PREFIX/bin"
elif [ -d "/opt/config/bin" ] && [ -w "/opt/config/bin" ]; then
  TARGET_DIR="/opt/config/bin"
elif [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
  TARGET_DIR="$HOME/.local/bin"
elif [ -w "/usr/local/bin" ]; then
  TARGET_DIR="/usr/local/bin"
else
  TARGET_DIR="$HOME/.local/bin"
  mkdir -p "$TARGET_DIR"
fi

echo "[*] Installing binary into: $TARGET_DIR"
ln -sfn "$BIN_SRC" "$TARGET_DIR/agent-sandbox"

# Create agy-sandbox compatibility symlink if wanted
if [ ! -e "$TARGET_DIR/agy-sandbox" ]; then
  cat <<'EOF' > "$TARGET_DIR/agy-sandbox"
#!/usr/bin/env bash
exec agent-sandbox agy "$@"
EOF
  chmod +x "$TARGET_DIR/agy-sandbox"
  echo "[*] Created agy-sandbox compatibility wrapper in $TARGET_DIR"
fi

echo "=== Installation complete ==="
echo "agent-sandbox is now ready to use:"
echo "  agent-sandbox --list-profile"
echo "  agent-sandbox <agent> --profile <name>"
