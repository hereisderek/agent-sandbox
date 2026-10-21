#!/usr/bin/env bash
# update.sh — install the latest agent-sandbox release, only when it is newer than the installed version.
#   update.sh [--check] [<install path>]
# --check only reports (exit 0 = up to date, 10 = a newer release exists, 3 = could not read the release).
# Default install path: the agent-sandbox found on PATH. Needs curl. One unauthenticated API request, one download when newer.
# A copy that is a symlink into a git clone is not touched: update those with `git pull`.
set -euo pipefail
REPO="hereisderek/agent-sandbox"
CHECK=0; [ "${1:-}" = "--check" ] && { CHECK=1; shift; }
DEST="${1:-$(command -v agent-sandbox || true)}"
[ -n "$DEST" ] || { echo "agent-sandbox not found; pass its install path" >&2; exit 2; }
DEST="$(readlink -f "$DEST")"
if git -C "$(dirname "$DEST")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "$DEST is inside a git checkout: update it with git pull" >&2; exit 2
fi

installed="$("$DEST" --version 2>/dev/null | awk '{print $2}' || true)"; installed="${installed:-0}"
latest="$(curl -fsSL -m 20 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true)"
[ -n "$latest" ] || { echo "could not read the latest release (offline, rate limited, or none yet)" >&2; exit 3; }
latest_v="${latest#v}"

if [ "$(printf '%s\n%s\n' "$installed" "$latest_v" | sort -V | tail -n 1)" = "$installed" ]; then
  echo "up to date: installed $installed, latest release $latest_v"; exit 0
fi
echo "newer release: $latest_v (installed $installed)"
[ "$CHECK" = 1 ] && exit 10

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -fsSL -m 60 -o "$tmp" "https://github.com/$REPO/releases/download/$latest/agent-sandbox"
bash -n "$tmp" && grep -q '^AGENT_SANDBOX_VERSION=' "$tmp" || { echo "downloaded file failed the sanity check, not installed" >&2; exit 1; }
if [ -w "$DEST" ] || [ -w "$(dirname "$DEST")" ]; then install -m 755 "$tmp" "$DEST"; else sudo install -m 755 "$tmp" "$DEST"; fi
echo "installed $latest_v at $DEST"
