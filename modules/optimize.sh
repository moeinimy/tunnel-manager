#!/usr/bin/env bash
# modules/optimize.sh — reversible network/kernel tuning for traffic forwarding.
#
# apply:  back up current sysctl values (once), drop a managed sysctl.d file,
#         enable BBR+fq, raise buffers, enable forwarding. All in one file so
#         removal is clean.
# revert: restore backed-up values, remove managed files.

TM_SYSCTL_FILE="/etc/sysctl.d/99-tunnel-manager.conf"
TM_MODULES_FILE="/etc/modules-load.d/tunnel-manager.conf"
TM_OPT_BACKUP="$TM_STATE_DIR/optimize.sysctl.bak"
TM_OPT_MARKER="$TM_STATE_DIR/optimize.applied"

# Keys we manage (kept in one place so backup/restore stay in sync).
_opt_keys() {
    cat <<'EOF'
net.ipv4.ip_forward
net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.rmem_max
net.core.wmem_max
net.core.rmem_default
net.core.wmem_default
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.core.netdev_max_backlog
net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_fastopen
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_tw_reuse
net.ipv4.udp_rmem_min
net.ipv4.udp_wmem_min
net.ipv4.conf.all.rp_filter
fs.file-max
EOF
}

# _opt_bbr_available — does the kernel offer BBR?
_opt_bbr_available() {
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

optimize_backup() {
    [[ -f "$TM_OPT_BACKUP" ]] && return 0   # never overwrite the pristine backup
    mkdir -p "$TM_STATE_DIR"
    local k v
    : >"$TM_OPT_BACKUP"
    while read -r k; do
        [[ -n "$k" ]] || continue
        v="$(sysctl -n "$k" 2>/dev/null || echo '__UNSET__')"
        printf '%s\t%s\n' "$k" "$v" >>"$TM_OPT_BACKUP"
    done < <(_opt_keys)
    log_debug "sysctl backup saved to $TM_OPT_BACKUP"
}

optimize_apply() {
    require_root
    ui_title "Network optimization"
    optimize_backup

    local cc="cubic" qdisc="fq"
    if _opt_bbr_available; then
        cc="bbr"
        printf 'tcp_bbr\n' >"$TM_MODULES_FILE"
        log_info "BBR available — enabling bbr + fq."
    else
        log_warn "BBR not available on this kernel — keeping current congestion control."
        cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
    fi

    cat >"$TM_SYSCTL_FILE" <<EOF
# Managed by Tunnel Manager — do not edit by hand.
# Remove via: tunnelctl optimize revert
net.ipv4.ip_forward = 1
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $cc

# Socket buffers (64 MiB ceilings) for high-BDP tunnels
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Queues / backlog / connection handling
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1

# Loose reverse-path filtering so asymmetric tunnel routing is not dropped
net.ipv4.conf.all.rp_filter = 2

# File descriptors
fs.file-max = 1000000
EOF

    if sysctl -p "$TM_SYSCTL_FILE" >/dev/null 2>&1; then
        log_ok "Applied sysctl tuning (congestion=$cc, qdisc=$qdisc)."
    else
        log_warn "Some sysctl keys were rejected by this kernel (applied the rest)."
    fi

    touch "$TM_OPT_MARKER"
    log_ok "Optimization applied. Reversible with: tunnelctl optimize revert"
}

optimize_revert() {
    require_root
    if [[ ! -f "$TM_OPT_BACKUP" ]]; then
        log_warn "No optimization backup found; nothing to revert."
        rm -f "$TM_SYSCTL_FILE" "$TM_MODULES_FILE" "$TM_OPT_MARKER"
        return 0
    fi
    rm -f "$TM_SYSCTL_FILE" "$TM_MODULES_FILE"
    local k v
    while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] || continue
        [[ "$v" == "__UNSET__" ]] && continue
        sysctl -w "$k=$v" >/dev/null 2>&1 || true
    done <"$TM_OPT_BACKUP"
    # Reload remaining sysctl.d files so the managed file's effects are dropped.
    sysctl --system >/dev/null 2>&1 || true
    rm -f "$TM_OPT_BACKUP" "$TM_OPT_MARKER"
    log_ok "Reverted network optimization to original values."
}

optimize_status() {
    ui_title "Optimization status"
    if [[ -f "$TM_OPT_MARKER" ]]; then
        ui_kv "State" "$(status_dot up) applied"
    else
        ui_kv "State" "$(status_dot down) not applied"
    fi
    ui_kv "Congestion" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    ui_kv "Qdisc"      "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    ui_kv "ip_forward" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    ui_kv "rmem_max"   "$(sysctl -n net.core.rmem_max 2>/dev/null)"
}
