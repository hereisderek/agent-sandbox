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

# --- interactive mode: answers come from stdin. Listing order (agent, then name):
#     1 claude/auth  2 claude/fresh  3 claude/stale (*)  4 codex/authed  5 codex/old (*)
rm -rf "$B"; mkdir -p "$B/.net/claude"
mk claude auth  "$B/claude/auth/.claude.json"; age "$B/claude/auth"
mk claude fresh "$B/claude/fresh/skills/x"
mk claude stale "$B/claude/stale/skills/x";    age "$B/claude/stale"
mk codex  authed "$B/codex/authed/auth.json";  age "$B/codex/authed"
mk codex  old    "$B/codex/old/tmp/x";         age "$B/codex/old"
echo ipv6=host > "$B/.net/claude/stale.conf"; : > "$T/hook.log"
ia() { printf '%s\n' "$@" | "$SB" --auto-clean -i 2>&1; }

out="$(ia q)"
check "interactive lists all profiles"          bash -c "[ \$(grep -cE '^ *[0-9]+\)' <<< '$out') -eq 5 ]"
check "flagged ones carry a *"                  grep -qE '[0-9]\) \* claude +stale' <<< "$out"
check "authenticated ones are not flagged"      bash -c "! grep -qE '[0-9]\) \* +(claude +auth|codex +authed)' <<< '$out'"
check "q removes nothing"                       test -d "$B/claude/stale"

ia 2 n >/dev/null
check "answering n removes nothing"             test -d "$B/claude/fresh"
check "out-of-range returns failure"            bash -c "! printf '99\n' | '$SB' --auto-clean -i >/dev/null 2>&1"
check "bad token returns failure"               bash -c "! printf 'x1\n' | '$SB' --auto-clean -i >/dev/null 2>&1"
check "trailing hyphen returns failure"         bash -c "! printf '3-\n' | '$SB' --auto-clean -i >/dev/null 2>&1"

ia 2 y >/dev/null
check "picking an unflagged unauthenticated profile removes it (fresh)" test ! -e "$B/claude/fresh"

printf 'a\ny\n' | "$SB" --auto-clean -i >/dev/null 2>&1
check "a removes every * profile"               test ! -e "$B/claude/stale" -a ! -e "$B/codex/old"
check "its saved network choice is removed"     test ! -e "$B/.net/claude/stale.conf"
check "the hook was told to release it"         grep -qx 'release claude stale' "$T/hook.log"
check "authenticated profiles survive a"        test -d "$B/claude/auth" -a -d "$B/codex/authed"

printf '1\ny\n' | "$SB" --auto-clean -i >/dev/null 2>&1
check "authenticated pick: y is not enough"     test -d "$B/claude/auth"
printf '1\ndelete\n' | "$SB" --auto-clean -i >/dev/null 2>&1
check "authenticated pick: typing delete removes it" test ! -e "$B/claude/auth"
printf '1-2\n' | "$SB" --auto-clean -i --dry-run >/dev/null 2>&1
check "--dry-run with -i removes nothing"       test -d "$B/codex/authed"
printf 'q\n' | "$SB" --auto-clean codex --interactive >/dev/null 2>&1
check "--interactive and an agent filter work"  test -d "$B/codex/authed"

exit $fail
