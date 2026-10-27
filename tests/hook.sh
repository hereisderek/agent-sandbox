#!/usr/bin/env bash
# Tests for examples/net-hook-lxc.sh with ip, ping and sudo faked (no root, no network).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/examples/net-hook-lxc.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/base"
export TESTDIR="$T" AGENT_SANDBOX_BASE="$T/base" PATH="$T/bin:$PATH"
PFX=2404:4400:4172:e900

cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "-6 route show default") echo "default via fe80::1 dev eth0 proto ra metric 1024" ;;
  "-6 -o addr show dev eth0 scope global -deprecated")
    echo "2: eth0    inet6 2404:4400:4172:e900:be24:11ff:fe9e:3e48/64 scope global dynamic mngtmpaddr" ;;
  "-o addr show to "*) grep -qx "$5" "$TESTDIR/present" 2>/dev/null && echo "2: eth0 inet6 $5/128 scope global" ;;
  "-6 addr add "*) echo "$*" >> "$TESTDIR/added"; echo "${4%/128}" >> "$TESTDIR/present" ;;
esac
EOF
printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$T/bin/sudo"
printf '#!/bin/sh\ngrep -qx "$4" "$TESTDIR/busy" 2>/dev/null\n' > "$T/bin/ping"
chmod +x "$T/bin/"*
: > "$T/present"; : > "$T/busy"

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
reserve() { bash "$HOOK" reserve ipv6 "$1" "$2" 2>"$T/err"; }

# default pool: 128 addresses, ff00..ff7f
a1="$(reserve claude p1)"
case "$a1" in "$PFX":ffff:ffff:ffff:ff[0-7]?) ok "address inside default pool: $a1" ;; *) bad "address inside default pool: $a1" ;; esac
check "address configured" grep -qx "$a1" "$T/present"
check "added /128, no DAD, deprecated" grep -q "$a1/128 dev eth0 nodad valid_lft forever preferred_lft 0" "$T/added"
check "registry stores the interface id" grep -q "claude/p1	${a1#"$PFX":}" "$T/base/.net/ipv6.registry"

# stable per profile, distinct across profiles
check "same profile, same address" test "$(reserve claude p1)" = "$a1"
a2="$(reserve claude p2)"
check "other profile, other address" test "$a2" != "$a1"
check "no duplicate add" test "$(wc -l < "$T/added" | tr -d ' ')" = 2

# a busy candidate (something answers ping) is skipped
cand="$(reserve codex pb)"; echo "$cand" >> "$T/busy"
grep -v "codex/pb" "$T/base/.net/ipv6.registry" > "$T/reg" && mv "$T/reg" "$T/base/.net/ipv6.registry"
check "busy address skipped" test "$(reserve codex pb)" != "$cand"

# growing the pool never moves existing assignments
export AGENT_SANDBOX_V6_POOL=ffff:ffff:fff0:0000-ffff:ffff:ffff:ff7f
check "pool grown, p1 unchanged" test "$(reserve claude p1)" = "$a1"
a3="$(reserve claude p3)"
case "$a3" in "$PFX":*) ok "new profile allocates from the grown pool" ;; *) bad "new profile allocates from the grown pool" ;; esac

# exhaustion and anycast: ff7e..ff81 holds only two usable ids (ff80, ff81 are anycast)
rm -f "$T/base/.net/ipv6.registry"
export AGENT_SANDBOX_V6_POOL=ffff:ffff:ffff:ff7e-ffff:ffff:ffff:ff81
b1="$(reserve x a)"; b2="$(reserve x b)"
check "two usable ids handed out" test "$b1" != "$b2"
case "$b1$b2" in *ff80*|*ff81*) bad "anycast ids never handed out" ;; *) ok "anycast ids never handed out" ;; esac
check "third profile: pool exhausted" bash -c "! bash '$HOOK' reserve ipv6 x c 2>/dev/null"
export AGENT_SANDBOX_V6_POOL=ffff:ffff:ffff:ff7f-ffff:ffff:ffff:ff00
check "inverted pool rejected" bash -c "! bash '$HOOK' reserve ipv6 x d 2>/dev/null"
unset AGENT_SANDBOX_V6_POOL

# ensure: re-adds a registered address after it vanished; refuses everything else
: > "$T/present"
check "ensure re-adds a registered address" bash "$HOOK" ensure ipv6 "$b1"
check "ensure: present again" grep -qx "$b1" "$T/present"
check "ensure refuses another prefix" bash -c "! bash '$HOOK' ensure ipv6 2001:db8:0:1:ffff:ffff:ffff:ff10 2>/dev/null"
check "ensure refuses outside the pool" bash -c "! bash '$HOOK' ensure ipv6 $PFX:1:2:3:4 2>/dev/null"
check "ensure refuses anycast" bash -c "! bash '$HOOK' ensure ipv6 $PFX:ffff:ffff:ffff:ff90 2>/dev/null"
check "ipv4 is refused" bash -c "! bash '$HOOK' reserve ipv4 x y 2>/dev/null"

exit $fail
