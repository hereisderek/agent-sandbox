#!/usr/bin/env bash
# Example agent-sandbox net hook for a Linux host or LXC with SLAAC IPv6.
# Install: ln -s <repo>/examples/net-hook-lxc.sh <sandbox_base>/net-hook
#          (or set AGENT_SANDBOX_NET_HOOK to its path)
#
# Contract, called by agent-sandbox:
#   net-hook reserve <ipv4|ipv6> <agent> <profile>
#       Print an address for the profile. The same profile always gets the same one.
#   net-hook ensure  <ipv4|ipv6> <addr> [<agent> <profile>]
#       Make <addr> usable on this host now (for example after a reboot). Exit 0 = usable.
#   net-hook release <agent> <profile>
#       Optional. Called when a profile is deleted (--auto-clean): free its address.
#
# IPv6: addresses come from a range of interface IDs inside the interface's own /64.
# The /64 is read from the interface's SLAAC address, so a renumbered prefix needs
# no edits here: run `--ipv6 new` once and the profile gets the same ID in the new prefix.
#   AGENT_SANDBOX_V6_POOL    START-END interface IDs, 4 hex groups each. Default is the
#                            top of the /64 below the reserved block: 128 addresses.
#                            Grow it by lowering START; existing assignments are kept
#                            in the registry and never move.
#   AGENT_SANDBOX_NET_IFACE  interface to configure (default: that of the default IPv6 route)
#   AGENT_SANDBOX_NET_REGISTRY  profile -> interface ID map (default: <sandbox_base>/.net/ipv6.registry)
#
# Addresses are added as /128 with preferred_lft 0 (deprecated): the kernel never picks
# them as a default source, only a socket bound to one uses it. ::0 and the top 128 IDs
# of a /64 (ff80..ffff, RFC 2526) are anycast and are never handed out.
# IPv4 is not handled here: pass an address that already exists on the host.
set -euo pipefail

BASE="${AGENT_SANDBOX_BASE:-/opt/config/agent-sandbox}"
REGISTRY="${AGENT_SANDBOX_NET_REGISTRY:-$BASE/.net/ipv6.registry}"
POOL="${AGENT_SANDBOX_V6_POOL:-ffff:ffff:ffff:ff00-ffff:ffff:ffff:ff7f}"
IFACE="${AGENT_SANDBOX_NET_IFACE:-}"

die() { echo "net-hook: $*" >&2; exit 1; }
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi; }

# v6_expand <addr>: eight 4-digit groups, colon separated
v6_expand() {
  awk -v a="$1" 'BEGIN {
    n = index(a, "::")
    if (n) { h = substr(a, 1, n - 1); t = substr(a, n + 2) } else { h = a; t = "" }
    nh = (h == "") ? 0 : split(h, hh, ":")
    nt = (t == "") ? 0 : split(t, tt, ":")
    c = 0
    for (i = 1; i <= nh; i++) g[++c] = hh[i]
    if (n) for (i = 0; i < 8 - nh - nt; i++) g[++c] = "0"
    for (i = 1; i <= nt; i++) g[++c] = tt[i]
    for (i = 1; i <= 8; i++) {
      s = g[i]; while (length(s) < 4) s = "0" s
      printf "%s%s", s, (i < 8 ? ":" : "\n")
    }
  }'
}

# Interface IDs are 64-bit values held in bash's signed arithmetic; add, subtract and
# bit tests wrap correctly, so only offsets from the pool start are ever compared.
iid_num() { local h="${1//:/}"; echo $(( 16#$h )); }
iid_fmt() { printf '%016x' "$1" | sed 's/\(....\)/\1:/g; s/:$//'; }
iid_reserved() { [ "$1" -eq 0 ] || [ $(( $1 | 127 )) -eq -1 ]; }

pool_init() {
  [[ "$POOL" =~ ^[0-9a-f]{4}(:[0-9a-f]{4}){3}-[0-9a-f]{4}(:[0-9a-f]{4}){3}$ ]] \
    || die "invalid AGENT_SANDBOX_V6_POOL '$POOL' (want xxxx:xxxx:xxxx:xxxx-xxxx:xxxx:xxxx:xxxx)"
  POOL_START="$(iid_num "${POOL%-*}")"
  POOL_SIZE=$(( $(iid_num "${POOL#*-}") - POOL_START + 1 ))
  [ "$POOL_SIZE" -gt 0 ] || die "invalid AGENT_SANDBOX_V6_POOL '$POOL' (END before START)"
}

in_pool() { local off=$(( $1 - POOL_START )); [ "$off" -ge 0 ] && [ "$off" -lt "$POOL_SIZE" ]; }

iface_init() {
  if [ -z "$IFACE" ]; then
    IFACE="$(ip -6 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
  fi
  [ -n "$IFACE" ] || die "no IPv6 default route; set AGENT_SANDBOX_NET_IFACE"
}

# v6_prefix: the interface's /64 (first four groups of a non-deprecated global address)
v6_prefix() {
  local a
  a="$(ip -6 -o addr show dev "$IFACE" scope global -deprecated 2>/dev/null | awk '{ split($4, x, "/"); print x[1]; exit }')"
  [ -n "$a" ] || die "no global IPv6 address on $IFACE"
  v6_expand "$a" | cut -d: -f1-4
}

registry_iid() { awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$REGISTRY"; }
registry_has() { cut -f2 "$REGISTRY" | grep -qx "$1"; }

ensure_v6() {
  local addr="$1" iid
  if [ -n "$(ip -o addr show to "$addr" 2>/dev/null)" ]; then return 0; fi
  iface_init; pool_init
  [ "$(v6_expand "$addr" | cut -d: -f1-4)" = "$(v6_prefix)" ] \
    || die "$addr is not in the current prefix $(v6_prefix)::/64 (run --ipv6 new again)"
  iid="$(iid_num "$(v6_expand "$addr" | cut -d: -f5-8)")"
  if iid_reserved "$iid"; then die "$addr is an anycast address"; fi
  touch "$REGISTRY"
  in_pool "$iid" || registry_has "$(iid_fmt "$iid")" || die "$addr is outside the pool and the registry"
  as_root ip -6 addr add "$addr/128" dev "$IFACE" nodad valid_lft forever preferred_lft 0
}

reserve_v6() {
  local key="$1/$2" iid="" fmt start i idx
  iface_init; pool_init
  mkdir -p "$(dirname "$REGISTRY")"; touch "$REGISTRY"
  if command -v flock >/dev/null 2>&1; then exec 9>"$REGISTRY.lock"; flock 9; fi

  fmt="$(registry_iid "$key")"
  if [ -n "$fmt" ]; then
    iid="$(iid_num "$fmt")"
  else
    start=$(( $(printf '%s' "$key" | cksum | cut -d' ' -f1) % POOL_SIZE ))
    for (( i = 0; i < POOL_SIZE; i++ )); do
      idx=$(( POOL_START + (start + i) % POOL_SIZE ))
      if iid_reserved "$idx"; then continue; fi
      fmt="$(iid_fmt "$idx")"
      if registry_has "$fmt"; then continue; fi
      if ping -6 -c1 -W1 "$(v6_prefix):$fmt" >/dev/null 2>&1; then continue; fi
      iid="$idx"; break
    done
    [ -n "$iid" ] || die "IPv6 pool $POOL is exhausted; widen AGENT_SANDBOX_V6_POOL"
    printf '%s\t%s\n' "$key" "$(iid_fmt "$iid")" >> "$REGISTRY"
  fi

  local addr
  addr="$(v6_prefix):$(iid_fmt "$iid")"
  ensure_v6 "$addr"
  echo "$addr"
}

# release_v6 <agent> <profile>: forget the profile's ID (frees it for reuse) and drop the address
release_v6() {
  local key="$1/$2" fmt
  [ -f "$REGISTRY" ] || return 0
  if command -v flock >/dev/null 2>&1; then exec 9>"$REGISTRY.lock"; flock 9; fi
  fmt="$(registry_iid "$key")"
  [ -n "$fmt" ] || return 0
  awk -F'\t' -v k="$key" '$1 != k' "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
  # best effort: the address is only a deprecated /128 and goes away on reboot anyway
  ( iface_init; as_root ip -6 addr del "$(v6_prefix):$fmt/128" dev "$IFACE" ) 2>/dev/null || true
}

main() {
  case "${1:-}/${2:-}" in
    release/*)    release_v6 "${2:?agent}" "${3:?profile}" ;;
    reserve/ipv6) reserve_v6 "${3:?agent}" "${4:?profile}" ;;
    ensure/ipv6)  ensure_v6 "${3:?addr}" ;;
    reserve/ipv4|ensure/ipv4) die "IPv4 is not handled by this example hook" ;;
    *) die "usage: net-hook reserve|ensure <ipv4|ipv6> ... | release <agent> <profile>" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
