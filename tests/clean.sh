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
mk claude auth        "$B/claude/auth/.claude.json"; echo '{"oauthAccount":{"emailAddress":"a@b.c"}}' > "$B/claude/auth/.claude.json"; age "$B/claude/auth"
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
check "its saved network choice is moved out"  gone "$B/.net/claude/stale.conf"
check "the profile is in the trash, contents intact" bash -c "ls '$B'/.trash/*/claude/stale/skills/x >/dev/null"
check "its network choice is kept beside it"   bash -c "grep -q ipv6=host '$B'/.trash/*/claude/stale.net.conf"
check "the trash is not listed as a profile"   bash -c "! '$SB' --list-profile | grep -q trash"
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

# --- Claude login detection: .claude.json exists after the first run, so it only counts with an account or key
S="$T/status"; mkdir -p "$S"
cj() { mkdir -p "$S/claude/$1"; printf '%s\n' "$2" > "$S/claude/$1/${3:-.claude.json}"; }
cj first   '{"numStartups":3,"projects":{}}'
cj oauth   '{"oauthAccount": {"emailAddress": "a@b.c"}}'
cj nulled  '{"oauthAccount": null}'
cj apikey  '{"primaryApiKey": "sk-ant-x"}'
cj cred    '{"claudeAiOauth":{"accessToken":"x"}}' .credentials.json
mkdir -p "$S/claude/emptycr"; : > "$S/claude/emptycr/.credentials.json"
status_of() { AGENT_SANDBOX_BASE="$S" "$SB" claude --list-profile | awk -F'|' -v n="$1" '{ p=$3; gsub(/ /,"",p); if (p == n) { s=$6; gsub(/ /,"",s); print s } }'; }
check "first-run .claude.json only: not authenticated"    test "$(status_of first)"   = Initialized
check ".claude.json with an account: authenticated"       test "$(status_of oauth)"   = Authenticated
check "oauthAccount null: not authenticated"              test "$(status_of nulled)"  = Initialized
check ".claude.json with an API key: authenticated"       test "$(status_of apikey)"  = Authenticated
check "non-empty .credentials.json: authenticated"        test "$(status_of cred)"    = Authenticated
check "empty .credentials.json: not authenticated"        test "$(status_of emptycr)" = Initialized

# restore: moving a profile back out of the trash makes it a profile again
tdir="$(ls -d "$B"/.trash/*/ | head -1)"
if [ -d "${tdir}claude/stale" ]; then
  mv "${tdir}claude/stale" "$B/claude/stale"
  check "a restored profile is listed again"       bash -c "'$SB' claude --list-profile | grep -q ' stale '"
  rm -rf "$B/claude/stale"
fi

# --- interactive mode: keys come from stdin (one char at a time; a newline is Enter, \033[B is Down).
#     Row order (agent, then name): 1 claude/auth  2 claude/fresh  3 claude/stale (*)  4 codex/authed  5 codex/old (*)
rm -rf "$B"; mkdir -p "$B/.net/claude"
mk claude auth  "$B/claude/auth/.claude.json"; echo '{"oauthAccount":{"emailAddress":"a@b.c"}}' > "$B/claude/auth/.claude.json"; age "$B/claude/auth"
mk claude fresh "$B/claude/fresh/skills/x"
mk claude stale "$B/claude/stale/skills/x";    age "$B/claude/stale"
mk codex  authed "$B/codex/authed/auth.json";  age "$B/codex/authed"
mk codex  old    "$B/codex/old/tmp/x";         age "$B/codex/old"
echo ipv6=host > "$B/.net/claude/stale.conf"; : > "$T/hook.log"
keys() { printf "$1" | "$SB" --auto-clean -i "${@:2}" 2>&1; }

out="$(keys q)"
check "lists all five profiles, none selected"  bash -c "[ \$(grep -c '○' <<< '$out') -eq 5 ]"
check "the cursor starts on the first row"      grep -qE '^> ○   claude +auth' <<< "$out"
check "rows show the network info"              grep -qE 'claude +stale .*ipv4=.* ipv6=' <<< "$out"
check "flagged rows carry a *"                  grep -qE '○ \* claude +stale' <<< "$out"
check "authenticated rows are not flagged"      bash -c "! grep -qE '○ \* +(claude +auth|codex +authed)' <<< '$out'"
check "q removes nothing"                       test -d "$B/claude/stale"

keys ' ' >/dev/null
check "end of input without Enter removes nothing" test -d "$B/claude/stale" -a -d "$B/claude/auth"
keys '\033' >/dev/null
check "a lone Esc quits"                        test -d "$B/claude/auth"
keys 'j \nn\n' >/dev/null
check "toggle, Enter, answer n: nothing removed" test -d "$B/claude/fresh"
out="$(keys '\n')";   check "Enter with nothing selected says so"  grep -q 'Nothing selected' <<< "$out"
out="$(keys 'sn\n')"; check "n clears the selection"                grep -q 'Nothing selected' <<< "$out"
check "and nothing was removed"                 test -d "$B/claude/stale"

keys 'j \ny\n' >/dev/null
check "j then space then Enter then y removes row 2 (fresh)" test ! -e "$B/claude/fresh"
mk claude fresh "$B/claude/fresh/skills/x"
keys '\033[B\033[B\033[A \ny\n' >/dev/null
check "arrow keys move: Down Down Up lands on row 2" test ! -e "$B/claude/fresh"

keys 's\ny\n' >/dev/null
check "s selects every * row and they are removed" test ! -e "$B/claude/stale" -a ! -e "$B/codex/old"
check "its saved network choice is removed"     test ! -e "$B/.net/claude/stale.conf"
check "the hook was told to release it"         grep -qx 'release claude stale' "$T/hook.log"
check "authenticated profiles survive a"        test -d "$B/claude/auth" -a -d "$B/codex/authed"

keys ' \ny\n' >/dev/null
check "authenticated pick: y is not enough"     test -d "$B/claude/auth"
out="$(keys 'a\n' --dry-run)"
rows="$(grep -c '○' <<< "$out")"; sel="$(grep -c '^  [a-z0-9]*/' <<< "$out")"
check "a ticks every listed profile ($sel of $rows)" test "$rows" -ge 2 -a "$sel" -eq "$rows"
out="$(keys 'a\ny\n')"
check "a includes credentialed ones, so y is not enough" test -d "$B/claude/auth" -a -d "$B/codex/authed"
check "the footer says what the keys do"        grep -q 'tick all' <<< "$out"
keys ' \ndelete\n' >/dev/null
check "authenticated pick: typing delete removes it" test ! -e "$B/claude/auth"
keys ' j \n' --dry-run >/dev/null
check "--dry-run with -i removes nothing"       test -d "$B/codex/authed"
keys 'q' codex >/dev/null
check "an agent filter works"                   test -d "$B/codex/authed"
check "--interactive is an alias"               bash -c "printf q | '$SB' --auto-clean --interactive >/dev/null"

exit $fail
