#!/usr/bin/env bash
# modules/peer.sh — remote peer management.
#
# Iran servers usually can't reach api.telegram.org, so the Telegram bot runs on
# the foreign server. To let that one bot see/-control the Iran side too, we
# register the Iran box as a "peer" reachable over the tunnel's inner IP by SSH,
# and run `tunnelctl` on it remotely.

TM_PEERS_FILE="$TM_CONFIG_DIR/peers.conf"
TM_PEER_KEY="$TM_CONFIG_DIR/id_tm"

# peer_key_ensure — create a dedicated SSH keypair for peer control if missing.
peer_key_ensure() {
    [[ -f "$TM_PEER_KEY" ]] && return 0
    mkdir -p "$TM_CONFIG_DIR"
    ssh-keygen -t ed25519 -N '' -C "tunnel-manager@$(hostname)" -f "$TM_PEER_KEY" >/dev/null 2>&1 \
        || { log_error "ssh-keygen failed (is openssh-client installed?)"; return 1; }
    chmod 600 "$TM_PEER_KEY"
    log_ok "Generated peer control key: ${TM_PEER_KEY}.pub"
}

# peer_pubkey — print the public key to authorise on peers.
peer_pubkey() { cat "${TM_PEER_KEY}.pub" 2>/dev/null; }

# _ssh_opts — common non-interactive SSH options.
_ssh_opts() {
    printf '%s' "-i $TM_PEER_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 -o ServerAliveInterval=5"
}

peer_list() {
    [[ -f "$TM_PEERS_FILE" ]] || return 0
    awk -F'\t' 'NF>=2 {print $1"\t"$2}' "$TM_PEERS_FILE"
}

peer_target() {
    [[ -f "$TM_PEERS_FILE" ]] || return 1
    awk -F'\t' -v n="$1" '$1==n {print $2; exit}' "$TM_PEERS_FILE"
}

peer_exists() { [[ -n "$(peer_target "$1" 2>/dev/null)" ]]; }

# peer_add — interactive/registration of a peer, verifying connectivity.
peer_add() {
    require_root
    ensure_dirs
    peer_key_ensure || return 1
    local name target
    ask_valid name "Peer name (e.g. iran)" is_tunnel_name
    ask target "SSH target (user@host, host reachable over the tunnel, e.g. root@10.20.0.6)" ""
    [[ -n "$target" ]] || { log_error "empty target"; return 1; }

    log_info "Authorise this key on the peer first:"
    printf '\n  %s%s%s\n\n' "$C_YELLOW" "$(peer_pubkey)" "$C_RESET"
    printf 'On the peer run:\n  mkdir -p ~/.ssh && echo "%s" >> ~/.ssh/authorized_keys\n\n' "$(peer_pubkey)"
    confirm "Have you added the key on the peer?" no || { log_warn "Aborted."; return 1; }

    log_info "Testing SSH to $target …"
    # shellcheck disable=SC2046
    if ssh $(_ssh_opts) "$target" 'echo ok' 2>/dev/null | grep -q ok; then
        mkdir -p "$TM_CONFIG_DIR"; touch "$TM_PEERS_FILE"
        # replace any existing entry with this name
        local tmp; tmp="$(mktemp)"
        awk -F'\t' -v n="$name" '$1!=n' "$TM_PEERS_FILE" >"$tmp" 2>/dev/null || true
        printf '%s\t%s\n' "$name" "$target" >>"$tmp"
        mv -f "$tmp" "$TM_PEERS_FILE"; chmod 600 "$TM_PEERS_FILE"
        log_ok "Peer '$name' added ($target)."
    else
        log_error "SSH test failed. Check the key is authorised and $target is reachable."
        return 1
    fi
}

peer_remove() {
    require_root
    local name="$1"; [[ -n "$name" ]] || { peer_pick name || return 0; }
    [[ -f "$TM_PEERS_FILE" ]] || return 0
    local tmp; tmp="$(mktemp)"
    awk -F'\t' -v n="$name" '$1!=n' "$TM_PEERS_FILE" >"$tmp" && mv -f "$tmp" "$TM_PEERS_FILE"
    log_ok "Peer '$name' removed."
}

peer_pick() {
    local __v="$1" sel; local -a p
    mapfile -t p < <(peer_list | cut -f1)
    [[ ${#p[@]} -gt 0 ]] || { log_warn "No peers configured."; return 1; }
    ask_menu sel "Select a peer" "${p[@]}"
    printf -v "$__v" '%s' "$sel"
}

# peer_run NAME CMD... — run `tunnelctl CMD...` on the named peer, print output.
peer_run() {
    local name="$1"; shift
    local target; target="$(peer_target "$name")"
    [[ -n "$target" ]] || { echo "unknown peer: $name"; return 1; }
    # shellcheck disable=SC2046
    NO_COLOR=1 ssh $(_ssh_opts) "$target" "NO_COLOR=1 tunnelctl $*" 2>&1
}

# peer_overview — show configured peers on the CLI.
peer_overview() {
    ui_title "Peers"
    local any=0 name target
    while IFS=$'\t' read -r name target; do
        [[ -n "$name" ]] || continue
        any=1
        local state="unreachable"
        # shellcheck disable=SC2046
        ssh $(_ssh_opts) "$target" 'echo ok' >/dev/null 2>&1 && state="reachable"
        ui_kv "$name" "$target  ($(status_dot "$( [[ $state == reachable ]] && echo up || echo down )") $state)"
    done < <(peer_list)
    (( any )) || printf '  %sNo peers configured.%s\n' "$C_DIM" "$C_RESET"
}
