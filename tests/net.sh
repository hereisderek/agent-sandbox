#!/usr/bin/env bash
# Dry-run tests for --ipv4/--ipv6 handling in bin/agent-sandbox.
# Needs no root, bwrap, pasta or network: ip, bwrap, claude and the net hook are faked.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/base"
export HOME="$T/home" AGENT_SANDBOX_BASE="$T/base" AGENT_SANDBOX_DRY_RUN=1 TESTDIR="$T"
export PATH="$T/bin:$PATH"
unset AGENT_SANDBOX_NET_HOOK

A6=2404:4400:4172:e900:ffff:ffff:ffff:ff00
B6=2404:4400:4172:e900:ffff:ffff:ffff:ff01

printf '#!/bin/sh\nexit 0\n' > "$T/bin/bwrap"
cp "$T/bin/bwrap" "$T/bin/claude"
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "-o addr show to "*) a="$5"; grep -qx "$a" "$TESTDIR/present" 2>/dev/null && echo "2: eth0 inet6 $a/128 scope global" ;;
  "-4 route get "*) echo "1.1.1.1 via 172.16.0.1 dev eth0 src 172.16.2.26 uid 1000" ;;
  "-6 route get "*) echo "2606:4700:4700::1111 from :: via fe80::1 dev eth0 src 2404:4400:4172:e900::26 metric 1024" ;;
esac
EOF
cat > "$T/base/net-hook" <<EOF
#!/bin/sh
echo "\$*" >> "\$TESTDIR/hooklog"
case "\$1" in
  reserve) echo $B6 ;;
  ensure) grep -qx "\$3" "\$TESTDIR/ensurable" 2>/dev/null && echo "\$3" >> "\$TESTDIR/present" ;;
esac
EOF
chmod +x "$T/bin/"* "$T/base/net-hook"
: > "$T/present"; : > "$T/ensurable"

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
has()      { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing: $3)"; printf '%s\n' "$2" | sed 's/^/       /' ;; esac; }
hasline()  { if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else bad "$1 (no line: $3)"; fi; }
hasnline() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then bad "$1 (unexpected line: $3)"; else ok "$1"; fi; }
conf() { cat "$T/base/.net/claude/$1.conf" 2>/dev/null; }

# run <profile> [flags...]: sets out (the command line), err (the log), rc
run() {
  local p="$1"; shift
  out="$("$ROOT/bin/agent-sandbox" claude --profile "$p" "$@" --version 2>"$T/err")"; rc=$?
  err="$(cat "$T/err")"
}

# 1. defaults: host network, nothing saved, log shows the host addresses
run d
hasline  "default: no pasta"  "$out" bwrap
hasnline "default: no pasta"  "$out" pasta
has      "default: log"       "$err" "ipv4=172.16.2.26 (default) ipv6=2404:4400:4172:e900::26 (default)"
[ ! -e "$T/base/.net/claude/d.conf" ] && ok "default: nothing saved" || bad "default: nothing saved"

# 2. explicit address: pasta binds outbound, choice is saved
echo "$A6" > "$T/present"
run s --ipv6 "$A6"
has      "flag: pasta args"   "$out" "pasta"$'\n'"--config-net"$'\n'"-o"$'\n'"$A6"$'\n'"--"$'\n'"bwrap"
has      "flag: log"          "$err" "ipv6=$A6 (flag)"
has      "flag: saved"        "$(conf s)" "ipv6=$A6"
has      "flag: env"          "$out" "AGENT_SANDBOX_IPV6"$'\n'"$A6"

# 3. next run uses the saved value
run s
has      "saved: log"         "$err" "ipv6=$A6 (saved)"
hasline  "saved: pasta"       "$out" pasta

# 4. saved address gone: fall back to default, keep the saved value
: > "$T/present"
run s
hasnline "fallback: no pasta" "$out" pasta
has      "fallback: log"      "$err" "WARN"
has      "fallback: source"   "$err" "(fallback)"
has      "fallback: kept"     "$(conf s)" "ipv6=$A6"

# 5. saved address gone but the hook can restore it
echo "$A6" > "$T/ensurable"
run s
hasline  "ensure: pasta"      "$out" pasta
has      "ensure: log"        "$err" "ipv6=$A6 (saved)"
: > "$T/present"; : > "$T/ensurable"

# 6. one family disabled
run n4 --ipv4 none
has      "ipv4 none: -6"      "$out" "pasta"$'\n'"--config-net"$'\n'"-6"$'\n'"--"
hasnline "ipv4 none: no -o"   "$out" "-o"
has      "ipv4 none: log"     "$err" "ipv4=none (flag)"
run n6 --ipv6 none
hasline  "ipv6 none: -4"      "$out" "-4"

# 7. both disabled: no network at all, null is an alias for none
run nn --ipv4 none --ipv6 null
hasline  "both none: unshare" "$out" "--unshare-net"
hasnline "both none: no pasta" "$out" pasta
has      "both none: saved 4" "$(conf nn)" "ipv4=none"
has      "both none: saved 6" "$(conf nn)" "ipv6=none"
has      "both none: env"     "$out" "AGENT_SANDBOX_IPV4"$'\n'"none"

# 8. 'default' clears one family
run nn --ipv6 default
has      "reset: kept ipv4"   "$(conf nn)" "ipv4=none"
case "$(conf nn)" in *ipv6=*) bad "reset: ipv6 cleared" ;; *) ok "reset: ipv6 cleared" ;; esac

# 9. 'new' asks the hook, which also has to make the address present
echo "$B6" > "$T/ensurable"
run nw --ipv6 new
hasline  "new: -o"            "$out" "$B6"
has      "new: saved"         "$(conf nw)" "ipv6=$B6"
mv "$T/base/net-hook" "$T/net-hook.off"
run nw2 --ipv6 new
[ "$rc" -ne 0 ] && ok "new without hook fails" || bad "new without hook fails"
mv "$T/net-hook.off" "$T/base/net-hook"

# 10. bad input and unavailable explicit address are errors and save nothing
run bad --ipv6 bogus
[ "$rc" -ne 0 ] && ok "invalid value fails" || bad "invalid value fails"
run un --ipv6 "$A6"
[ "$rc" -ne 0 ] && ok "unavailable flag address fails" || bad "unavailable flag address fails"
[ ! -e "$T/base/.net/claude/un.conf" ] && ok "failed runs save nothing" || bad "failed runs save nothing"
"$ROOT/bin/agent-sandbox" claude --ipv6 none --version >/dev/null 2>&1
[ $? -ne 0 ] && ok "flags need --profile" || bad "flags need --profile"

# 11. list shows saved choices
mkdir -p "$T/base/claude/nn"
listing="$("$ROOT/bin/agent-sandbox" claude --list-profile 2>&1)"
has      "list: overrides"    "$listing" "claude/nn: ipv4=none"

# 12. default policy 'new': one command, no flags. Reserve once, then reuse.
: > "$T/present"; echo "$B6" > "$T/ensurable"
export AGENT_SANDBOX_DEFAULT_IPV6=new
run pol
hasline  "policy new: -o"       "$out" "$B6"
has      "policy new: log"      "$err" "ipv6=$B6 (auto)"
has      "policy new: saved"    "$(conf pol)" "ipv6=$B6"
run pol
has      "policy new: reused"   "$err" "ipv6=$B6 (saved)"
run pol --ipv6 default
has      "default: re-resolves to the policy" "$err" "ipv6=$B6 (auto)"
has      "default: same address again"        "$(conf pol)" "ipv6=$B6"
# 'host' pins the host address even while the policy says new
run pol --ipv6 host
hasnline "host: no pasta"       "$out" pasta
has      "host: saved"          "$(conf pol)" "ipv6=host"
run pol
has      "host: stays pinned"   "$err" "ipv6=2404:4400:4172:e900::26 (saved)"
# a profile with no saved v4 follows the policy for v4 too, independent of v6
unset AGENT_SANDBOX_DEFAULT_IPV6

# 13. policy from <base>/.net/defaults.conf; env wins over the file
mkdir -p "$T/base/.net"; echo "ipv6=none" > "$T/base/.net/defaults.conf"
run cf
hasline  "defaults.conf: -4"    "$out" "-4"
has      "defaults.conf: log"   "$err" "ipv6=none (auto)"
[ ! -e "$T/base/.net/claude/cf.conf" ] && ok "defaults.conf: none/address policies are not saved" || bad "defaults.conf: not saved"
AGENT_SANDBOX_DEFAULT_IPV6=host run cf2
hasnline "env beats file"       "$out" pasta
rm -f "$T/base/.net/defaults.conf"

# 14. listings show the address each profile uses, and never reserve or save anything
C="$T/base/.net/claude"; mkdir -p "$C"
for n in plain pinned gone off; do mkdir -p "$T/base/claude/ls-$n"; done
echo "$A6" > "$T/present"
echo "ipv6=$A6" > "$C/ls-pinned.conf"
echo "ipv6=$B6" > "$C/ls-gone.conf"            # saved, but not on this host
echo "ipv4=none" > "$C/ls-off.conf"
listing="$("$ROOT/bin/agent-sandbox" claude --list-profile 2>&1)"
has      "list: network block"      "$listing" "Network:"
has      "list: host address"       "$listing" "claude/ls-plain: ipv4=172.16.2.26 (host)  ipv6=2404:4400:4172:e900::26 (host)"
has      "list: saved address"      "$listing" "claude/ls-pinned: ipv4=172.16.2.26 (host)  ipv6=$A6 (saved)"
has      "list: saved but missing"  "$listing" "claude/ls-gone: ipv4=172.16.2.26 (host)  ipv6=$B6 (saved, not on this host)"
has      "list: disabled family"    "$listing" "claude/ls-off: ipv4=none (saved)"
AGENT_SANDBOX_DEFAULT_IPV6=new "$ROOT/bin/agent-sandbox" claude --list-profile 2>&1 | grep -qF "claude/ls-plain: ipv4=172.16.2.26 (host)  ipv6=new (reserved on first launch)" \
  && ok "list: policy new shown as pending" || bad "list: policy new shown as pending"
[ ! -e "$C/ls-plain.conf" ] && ok "list: reserved and saved nothing" || bad "list: reserved and saved nothing"
cl="$("$ROOT/bin/agent-sandbox" --auto-clean --dry-run --days 0 2>&1)"
has      "auto-clean: shows the address" "$cl" "ipv6=$B6 (saved, not on this host)"

# 15. auto / auto-strict: reuse the saved address, else reserve and save one, else host (or fail)
C="$T/base/.net/claude"; mkdir -p "$C"
unset AGENT_SANDBOX_DEFAULT_IPV6
: > "$T/present"; : > "$T/ensurable"; : > "$T/hooklog"
reserved() { grep -q '^reserve' "$T/hooklog"; }

# 15a. a saved address that is present is reused, the hook is not asked
echo "ipv6=$A6" > "$C/au1.conf"; echo "$A6" > "$T/present"
run au1 --ipv6 auto
hasline  "auto: reuses the saved address"   "$out" "$A6"
has      "auto: logged as saved"            "$err" "ipv6=$A6 (saved)"
check_not() { if "${@:2}"; then bad "$1"; else ok "$1"; fi; }
check_not "auto: did not ask the hook to reserve" reserved

# 15b. nothing saved: reserve, save, use; the next launch reuses it without the hook
: > "$T/present"; echo "$B6" > "$T/ensurable"; : > "$T/hooklog"
run au2 --ipv6 auto
hasline  "auto: uses a new address"         "$out" "$B6"
has      "auto: logged as new"              "$err" "ipv6=$B6 (new)"
has      "auto: new address saved"          "$(conf au2)" "ipv6=$B6"
check_not "auto: the word auto is never saved" grep -q auto "$C/au2.conf"
: > "$T/hooklog"
run au2 --ipv6 auto
has      "auto: second launch reuses it"    "$err" "ipv6=$B6 (saved)"
check_not "auto: second launch needs no reserve" reserved

# 15c. a saved address that is gone and cannot be restored is replaced by a new one
echo "ipv6=$A6" > "$C/au3.conf"; : > "$T/present"; echo "$B6" > "$T/ensurable"
run au3 --ipv6 auto
has      "auto: stale saved address replaced" "$err" "ipv6=$B6 (new)"
has      "auto: replacement saved"          "$(conf au3)" "ipv6=$B6"

# 15d. a saved 'host' (an explicit pin) is not an address: auto reserves one
echo "ipv6=host" > "$C/au4.conf"; : > "$T/present"; echo "$B6" > "$T/ensurable"
run au4 --ipv6 auto
has      "auto: saved host is replaced by a new address" "$err" "ipv6=$B6 (new)"

# 15e. last resort: no address available. auto falls back to the host, auto-strict fails
mv "$T/base/net-hook" "$T/net-hook.off"; : > "$T/present"
run au5 --ipv6 auto
[ "$rc" -eq 0 ] && ok "auto: no hook is not an error" || bad "auto: no hook is not an error"
has      "auto: warns about the host address" "$err" "using the host address"
has      "auto: logged as fallback"         "$err" "(fallback)"
hasnline "auto: fallback runs without pasta" "$out" pasta
[ ! -e "$C/au5.conf" ] && ok "auto: fallback saves nothing" || bad "auto: fallback saves nothing"
run au6 --ipv6 auto-strict
[ "$rc" -ne 0 ] && ok "auto-strict: fails with no address" || bad "auto-strict: fails with no address"
has      "auto-strict: says why"            "$err" "does not fall back to the host address"
[ ! -e "$C/au6.conf" ] && ok "auto-strict: failure saves nothing" || bad "auto-strict: failure saves nothing"
mv "$T/net-hook.off" "$T/base/net-hook"

# 15f. auto-strict still reuses a saved address and still reserves when it can
echo "ipv6=$A6" > "$C/au7.conf"; echo "$A6" > "$T/present"
run au7 --ipv6 auto-strict
[ "$rc" -eq 0 ] && has "auto-strict: reuses the saved address" "$err" "ipv6=$A6 (saved)" || bad "auto-strict: reuses the saved address"
: > "$T/present"; echo "$B6" > "$T/ensurable"
run au8 --ipv6 auto-strict
has      "auto-strict: reserves when nothing is saved" "$err" "ipv6=$B6 (new)"

# 15g. as a default policy, and for IPv4 (the example hook only answers IPv6: host fallback)
: > "$T/present"; echo "$B6" > "$T/ensurable"
AGENT_SANDBOX_DEFAULT_IPV6=auto run au9
has      "policy auto: reserves and saves"  "$(conf au9)" "ipv6=$B6"
run au10 --ipv4 auto
[ "$rc" -eq 0 ] && has "ipv4 auto: an invalid hook answer falls back to the host" "$err" "ipv4=172.16.2.26 (fallback)" || bad "ipv4 auto: falls back to the host"
run au11 --ipv6 bogus
has      "invalid value lists auto-strict"  "$err" "auto-strict"
listing="$("$ROOT/bin/agent-sandbox" claude --list-profile 2>&1)"
AGENT_SANDBOX_DEFAULT_IPV6=auto "$ROOT/bin/agent-sandbox" claude --list-profile 2>&1 | grep -qF "ipv6=auto (reserved on first launch)" \
  && ok "list: policy auto shown as pending" || bad "list: policy auto shown as pending"

exit $fail
