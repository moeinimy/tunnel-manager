#!/usr/bin/env bash
# modules/tunnel.sh — tunnel lifecycle: add / remove / edit / start / stop /
# restart / enable / disable / status, plus the internal __up/__down hooks that
# systemd invokes.

# pick_tunnel VAR — interactive selection; sets VAR to a tunnel name.
pick_tunnel() {
    local __v="$1" sel
    local -a t; mapfile -t t < <(list_tunnels)
    if [[ ${#t[@]} -eq 0 ]]; then log_warn "No tunnels defined yet."; return 1; fi
    ask_menu sel "Select a tunnel" "${t[@]}"
    printf -v "$__v" '%s' "$sel"
}

# ---------------------------------------------------------------------------
# Add
# ---------------------------------------------------------------------------
tunnel_add() {
    require_root
    ensure_dirs
    ui_title "Add tunnel"

    local name proto role
    while true; do
        ask_valid name "Tunnel name (a-z 0-9 - _)" is_tunnel_name
        if tunnel_exists "$name"; then log_warn "A tunnel named '$name' already exists."; continue; fi
        break
    done

    ask_menu proto "Protocol" gre paqet backhaul rathole gost frp
    ask_menu role  "Role of THIS server" iran foreign

    # Initialise a fresh profile.
    TUN=()
    TUN[NAME]="$name"
    TUN[PROTOCOL]="$proto"
    TUN[ROLE]="$role"
    TUN[AUTOSTART]="no"
    TUN[CREATED_AT]="$(date '+%Y-%m-%d %H:%M:%S')"

    # Protocol-specific questions populate the rest of TUN.
    driver_wizard || { log_error "wizard aborted"; return 1; }

    if ! driver_validate; then
        log_error "Validation failed; tunnel not created."
        [[ -n "${TUN[IPAM_INDEX]:-}" ]] && ipam_free "$name"
        return 1
    fi
    if ! profile_conflicts "$name" "$proto" "${TUN[LOCAL_IP]:-}" "${TUN[REMOTE_IP]:-}" \
                           "${TUN[PAQET_PORT]:-}" "${TUN[GRE_KEY]:-}"; then
        log_error "Conflicting configuration; tunnel not created."
        [[ -n "${TUN[IPAM_INDEX]:-}" ]] && ipam_free "$name"
        return 1
    fi

    save_tunnel
    svc_install "$name"
    log_ok "Tunnel '$name' created."

    if confirm "Enable auto-start on boot?" yes; then
        TUN[AUTOSTART]="yes"; save_tunnel; svc_enable "$name"
    fi
    if confirm "Start the tunnel now?" yes; then
        tunnel_start "$name"
    fi
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
tunnel_remove() {
    require_root
    local name="${1:-}"
    [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    confirm "Really remove tunnel '$name'? This tears it down." no || return 0

    load_tunnel "$name"
    svc_uninstall "$name"
    # Best-effort teardown in case the service was not running.
    driver_down 2>/dev/null || true
    [[ "${TUN[PROTOCOL]}" == paqet ]] && rm -f "$(paqet_cfg "$name")"
    [[ "${TUN[PROTOCOL]}" == backhaul ]] && rm -f "$(backhaul_cfg "$name")"
    [[ "${TUN[PROTOCOL]}" == rathole ]] && rm -f "$(rathole_cfg "$name")"
    [[ "${TUN[PROTOCOL]}" == gost ]] && rm -f "$(gost_wrapper "$name")"
    [[ "${TUN[PROTOCOL]}" == frp ]] && rm -f "$(frp_cfg "$name")"
    [[ -n "${TUN[IPAM_INDEX]:-}" ]] && ipam_free "$name"
    state_delete "$name"
    rm -f "$TM_STATE_DIR/history/${name}.hist"
    delete_tunnel_file "$name"
    log_ok "Tunnel '$name' removed."
    tg_notify "🗑️ Tunnel <b>$name</b> removed on $(hostname)"
}

# ---------------------------------------------------------------------------
# Edit (a focused subset of safely-editable fields)
# ---------------------------------------------------------------------------
tunnel_edit() {
    require_root
    local name="${1:-}"
    [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    load_tunnel "$name"

    local field
    ask_menu field "Field to edit" "MTU" "Auto-start" "Forwarding / ports" "Cancel"
    case "$field" in
        MTU)          ask_valid TUN[MTU] "New MTU" is_mtu "${TUN[MTU]}" ;;
        "Auto-start")
            if confirm "Enable auto-start?" yes; then TUN[AUTOSTART]=yes; svc_enable "$name"
            else TUN[AUTOSTART]=no; svc_disable "$name"; fi ;;
        "Forwarding / ports")
            if [[ "${TUN[PROTOCOL]}" == gre ]]; then
                if [[ "${TUN[ROLE]}" == iran ]]; then gre_wizard_forward_mode
                else log_warn "Forwarding is configured on the Iran side."; return 0; fi
            else paqet_wizard_forwards; fi ;;
        *) return 0 ;;
    esac
    save_tunnel
    svc_install "$name"
    log_ok "Updated '$name'. Restarting to apply…"
    tunnel_restart "$name"
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
tunnel_start() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    log_info "Starting '$name'…"
    if svc_start "$name"; then
        state_set "$name" STATUS up STARTED_AT "$(date +%s)" FAIL_COUNT 0
        log_ok "Tunnel '$name' started."
        tg_notify "🟢 Tunnel <b>$name</b> is UP on $(hostname)"
    else
        state_set "$name" STATUS down
        log_error "Failed to start '$name'. Check: journalctl -u $(unit_name "$name")"
        tg_notify "🔴 Tunnel <b>$name</b> FAILED to start on $(hostname)"
        return 1
    fi
}

tunnel_stop() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    svc_stop "$name" || true
    state_set "$name" STATUS down
    log_ok "Tunnel '$name' stopped."
    tg_notify "⏹️ Tunnel <b>$name</b> stopped on $(hostname)"
}

tunnel_restart() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    if svc_restart "$name"; then
        state_set "$name" STATUS up
        log_ok "Tunnel '$name' restarted."
    else
        state_set "$name" STATUS down
        log_error "Restart of '$name' failed."
        return 1
    fi
}

tunnel_enable() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    load_tunnel "$name" || { log_error "No such tunnel: $name"; return 1; }
    svc_enable "$name"; TUN[AUTOSTART]=yes; save_tunnel
    log_ok "Auto-start enabled for '$name'."
}

tunnel_disable() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    load_tunnel "$name" || { log_error "No such tunnel: $name"; return 1; }
    svc_disable "$name"; TUN[AUTOSTART]=no; save_tunnel
    log_ok "Auto-start disabled for '$name'."
}

# ---------------------------------------------------------------------------
# Internal hooks called by systemd units
# ---------------------------------------------------------------------------
tunnel_up_hook() {   # __up NAME
    local name="${1:-}"
    load_tunnel "$name" || die "unknown tunnel: $name"
    driver_up
    state_set "$name" STATUS up
}

tunnel_down_hook() { # __down NAME
    local name="${1:-}"
    load_tunnel "$name" || return 0
    driver_down
    state_set "$name" STATUS down
}

# ---------------------------------------------------------------------------
# Status / overview
# ---------------------------------------------------------------------------
tunnel_status() {
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    load_tunnel "$name" || { log_error "No such tunnel: $name"; return 1; }
    state_load "$name"

    ui_title "Tunnel: $name"
    local active="down"; svc_is_active "$name" && active="up"
    ui_kv "Service"    "$(status_dot "$active") $(svc_state "$name")  (autostart: $(svc_is_enabled "$name" && echo yes || echo no))"
    ui_kv "Protocol"   "${TUN[PROTOCOL]}   role: ${TUN[ROLE]}"
    driver_status
    # Live stats gathered by the monitor.
    local up_since="${ST[STARTED_AT]:-}"
    if [[ -n "$up_since" && "$active" == up ]]; then
        ui_kv "Uptime"  "$(human_duration "$(( $(date +%s) - up_since ))")"
    fi
    [[ -n "${ST[LATENCY_MS]:-}" ]] && ui_kv "Reachability" "${ST[LATENCY_MS]} ms  loss ${ST[LOSS_PCT]:-?}%  (${ST[PROBE]:-icmp} probe)"
    [[ -n "${ST[RX_RATE]:-}" ]]    && ui_kv "Rate"     "↓ $(human_bytes "${ST[RX_RATE]:-0}")/s   ↑ $(human_bytes "${ST[TX_RATE]:-0}")/s"
    [[ -n "${ST[RX_BYTES]:-}" ]]   && ui_kv "Total"    "↓ $(human_bytes "${ST[RX_BYTES]:-0}")   ↑ $(human_bytes "${ST[TX_BYTES]:-0}")"
}

# tunnel_overview — compact table of every tunnel.
tunnel_overview() {
    local -a t; mapfile -t t < <(list_tunnels)
    ui_title "Tunnels (${#t[@]})"
    if [[ ${#t[@]} -eq 0 ]]; then printf '  %sNo tunnels configured.%s\n' "$C_DIM" "$C_RESET"; return 0; fi
    printf '  %s%-16s %-7s %-8s %-8s %-22s%s\n' "$C_BOLD" "NAME" "PROTO" "ROLE" "STATE" "PEER" "$C_RESET"
    local n active peer
    for n in "${t[@]}"; do
        load_tunnel "$n"
        active="down"; svc_is_active "$n" && active="up"
        peer="${TUN[REMOTE_IP]:-?}"
        printf '  %-16s %-7s %-8s %s%-7s%s %-22s\n' \
            "$n" "${TUN[PROTOCOL]}" "${TUN[ROLE]}" "$(status_dot "$active")" " $active" "" "$peer"
    done
}

# tunnel_bandwidth — per-tunnel traffic table (current rate, peak, totals).
tunnel_bandwidth() {
    local -a t; mapfile -t t < <(list_tunnels)
    ui_title "Bandwidth"
    if [[ ${#t[@]} -eq 0 ]]; then printf '  %sNo tunnels.%s\n' "$C_DIM" "$C_RESET"; return 0; fi
    printf '  %s%-14s %-11s %-11s %-11s %-11s%s\n' "$C_BOLD" "NAME" "↓ now/s" "↑ now/s" "↓ total" "↑ total" "$C_RESET"
    local n
    for n in "${t[@]}"; do
        state_load "$n"
        printf '  %-14s %-11s %-11s %-11s %-11s\n' "$n" \
            "$(human_bytes "${ST[RX_RATE]:-0}")" "$(human_bytes "${ST[TX_RATE]:-0}")" \
            "$(human_bytes "${ST[RX_BYTES]:-0}")" "$(human_bytes "${ST[TX_BYTES]:-0}")"
    done
}

# tunnel_logs NAME — recent journal for the tunnel's unit.
tunnel_logs() {
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    journalctl -u "$(unit_name "$name")" -n 40 --no-pager 2>/dev/null || \
        log_warn "journalctl unavailable."
}
