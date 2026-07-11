#!/usr/bin/env bash
# modules/peer.sh — zero-config multi-server control over the tunnel.
#
# Iran boxes usually can't reach api.telegram.org, so the bot runs on the
# foreign server. To let that one bot see/control the Iran side too, every
# server runs a tiny "peer agent" (systemd socket + this handler) that answers
# a small allowlist of tunnelctl commands — but ONLY when the request comes in
# over a tunnel interface, from the connected tunnel peer's inner IP. Because
# the tunnel is a private point-to-point link, no keys or manual setup are
# needed: as soon as a tunnel is up, its remote end is controllable.

TM_AGENT_ALLOW=(list status bandwidth report logs)   # read-only + restart below

# ---------------------------------------------------------------------------
# Server side — invoked per connection by tm-agent@.service (Accept=yes).
# ---------------------------------------------------------------------------
agent_serve() {
    local src="${REMOTE_ADDR:-}" line
    src="${src#::ffff:}"                     # normalise IPv4-mapped IPv6
    read -r line || return 0

    # Authorise: source must be the inner IP of a configured tunnel's peer.
    local ok=no n
    while read -r n; do
        [[ -n "$n" ]] || continue
        load_tunnel "$n" 2>/dev/null || continue
        if [[ "${TUN[INNER_REMOTE]:-}" == "$src" ]]; then ok=yes; break; fi
    done < <(list_tunnels)
    if [[ "$ok" != yes ]]; then printf 'forbidden (source %s)\n' "$src"; return 0; fi

    # Allowlist the command; arguments are passed to tunnelctl as argv (never
    # shell-evaluated), so there is no injection surface.
    # shellcheck disable=SC2086
    set -- $line
    local cmd="${1:-}"
    case "$cmd" in
        list|status|bandwidth|usage|traffic|report|logs|restart)
            NO_COLOR=1 "$TM_CTL" "$@" 2>&1 ;;
        *)  printf 'denied: %s\n' "$cmd" ;;
    esac
}

# agent_firewall ensure|remove — allow the agent port only on tunnel interfaces
# (tm*), and drop it everywhere else (blocks public/spoofed access).
agent_firewall() {
    local action="${1:-ensure}"
    local fn=_ipt_ensure; [[ "$action" == remove ]] && fn=_ipt_remove
    "$fn" filter INPUT -p tcp --dport "$TM_AGENT_PORT" -i 'tm+' -j ACCEPT
    "$fn" filter INPUT -p tcp --dport "$TM_AGENT_PORT" -j DROP
}

# ---------------------------------------------------------------------------
# Client side — query a peer over the tunnel.
# ---------------------------------------------------------------------------
# agent_query IP CMD... — send CMD to the agent at IP, print its reply.
agent_query() {
    local ip="$1"; shift
    TQ_IP="$ip" TQ_PORT="$TM_AGENT_PORT" TQ_CMD="$*" timeout 8 bash -c '
        exec 3<>"/dev/tcp/$TQ_IP/$TQ_PORT" || exit 1
        printf "%s\n" "$TQ_CMD" >&3
        cat <&3
    ' 2>/dev/null || { echo "(peer unreachable)"; return 1; }
}

# Peers are auto-derived from tunnels: each tunnel's remote inner IP is a peer.
# peer_list -> lines "tunnelname<TAB>inner_remote"
peer_list() {
    local n
    while read -r n; do
        [[ -n "$n" ]] || continue
        load_tunnel "$n" 2>/dev/null || continue
        [[ -n "${TUN[INNER_REMOTE]:-}" ]] && printf '%s\t%s\n' "$n" "${TUN[INNER_REMOTE]}"
    done < <(list_tunnels)
}

# peer_run NAME CMD... — run a command on the peer reached via tunnel NAME.
# NAME may be a tunnel name or a raw inner IP.
peer_run() {
    local name="$1"; shift
    local ip="$name"
    if tunnel_exists "$name"; then load_tunnel "$name"; ip="${TUN[INNER_REMOTE]}"; fi
    [[ -n "$ip" ]] || { echo "unknown peer: $name"; return 1; }
    agent_query "$ip" "$@"
}

# peer_overview — list auto-discovered peers and their reachability.
peer_overview() {
    ui_title "Peers (auto-discovered from tunnels)"
    local any=0 name ip
    while IFS=$'\t' read -r name ip; do
        [[ -n "$name" ]] || continue
        any=1
        local reply; reply="$(agent_query "$ip" list 2>/dev/null | head -1)"
        if [[ -n "$reply" && "$reply" != "(peer unreachable)" ]]; then
            ui_kv "$name" "$ip  ($(status_dot up) agent reachable)"
        else
            ui_kv "$name" "$ip  ($(status_dot down) no agent — update the peer to v1.2+)"
        fi
    done < <(peer_list)
    (( any )) || printf '  %sNo tunnels yet — peers appear automatically once a tunnel is up.%s\n' "$C_DIM" "$C_RESET"
}
