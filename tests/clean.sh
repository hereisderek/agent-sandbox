#!/usr/bin/env bash
# Tests for `agent-sandbox --auto-clean` against a throwaway profile base (nothing real is touched).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$ROOT/bin/agent-sandbox"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export AGENT_SANDBOX_BASE="$T/base"
B="$T/base"

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
gone() { [ ! -e "$1" ]; }
age() { find "$1" -exec touch -h -t 202001010000 {} +; }   # make a profile look untouched for years

mk() { mkdir -p "$B/$1/$2"; shift 2; for f in "$@"; do mkdir -p "$(dirname "$f")"; : > "$f"; done; }
mk claude auth        "$B/claude/auth/.claude.json";   age "$B/claude/auth"
mk claude stale       "$B/claude/stale/skills/x";      age "$B/claude/stale"
mk claude fresh       "$B/claude/fresh/skills/x"
mk codex  authed      "$B/codex/authed/auth.json";     age "$B/codex/authed"
mk codex  old-new     "$B/codex/old-new/tmp/x";        age "$B/codex/old-new"
mkdir -p "$B/.net/claude" "$B/.net/codex"
echo ipv6=host > "$B/.net/claude/stale.conf"; echo ipv6=host > "$B/.net/claude/auth.conf"

# a hook that records release calls
cat > "$T/hook" <<EOS
#!/bin/sh
echo "\$*" >> "$T/hook.log"
EOS
chmod +x "$T/hook"; export AGENT_SANDBOX_NET_HOOK="$T/hook"

out="$("$SB" --auto-clean --dry-run 2>&1)"
check "dry-run lists the stale profile"        grep -q 'claude/stale' <<< "$out"
check "dry-run lists the old empty codex one"  grep -q 'codex/old-new' <<< "$out"
check "dry-run skips authenticated profiles"   bash -c "! grep -qE 'claude/auth|codex/authed' <<< '$out'"
check "dry-run skips recently used profiles"   bash -c "! grep -q 'claude/fresh' <<< '$out'"
check "dry-run deletes nothing"                test -d "$B/claude/stale"

check "no terminal and no --yes: refuses"      bash -c "! '$SB' --auto-clean </dev/null >/dev/null 2>&1"
check "refusal deletes nothing"                test -d "$B/claude/stale"

"$SB" --auto-clean claude --yes >/dev/null 2>&1
check "--yes removes the stale profile"        gone "$B/claude/stale"
check "its saved network choice is removed"    gone "$B/.net/claude/stale.conf"
check "the hook was told to release it"        grep -qx 'release claude stale' "$T/hook.log"
check "authenticated profile kept"             test -d "$B/claude/auth"
check "its network choice kept"                test -f "$B/.net/claude/auth.conf"
check "recently used profile kept"             test -d "$B/claude/fresh"
check "other agents untouched when one is named" test -d "$B/codex/old-new"

"$SB" --auto-clean --yes >/dev/null 2>&1
check "all-agents run removes the old empty codex profile" gone "$B/codex/old-new"
check "authenticated codex profile kept"       test -d "$B/codex/authed"

"$SB" --auto-clean --days 0 --yes >/dev/null 2>&1
check "--days 0 also removes a fresh unauthenticated profile" gone "$B/claude/fresh"
check "--days 0 still keeps authenticated ones" test -d "$B/claude/auth"

check "bad --days rejected"                    bash -c "! '$SB' --auto-clean --days abc >/dev/null 2>&1"
check "unknown agent rejected"                 bash -c "! '$SB' --auto-clean nosuch >/dev/null 2>&1"
check "nothing left to clean is not an error"  bash -c "$SB --auto-clean --yes >/dev/null"

exit $fail
