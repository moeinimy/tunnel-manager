#!/usr/bin/env bash
# modules/report.sh — daily/weekly/monthly reports (text/HTML), sent to Telegram
# and printed on the CLI.

# report_build PERIOD -> prints an HTML report suitable for Telegram.
report_build() {
    local period="${1:-daily}" out title
    case "$period" in
        weekly)  title="Weekly report" ;;
        monthly) title="Monthly report" ;;
        *)       title="Daily report"; period=daily ;;
    esac

    # System snapshot (from monitor state, with live fallback).
    local cpu mem disk up
    if [[ -f "$TM_SYS_STATE" ]]; then . "$TM_SYS_STATE"; fi
    cpu="${CPU_PCT:-$(monitor_cpu_pct 2>/dev/null || echo 0)}"
    mem="${MEM_PCT:-$(free | awk '/^Mem:/{printf "%d", ($2? ($2-$7)*100/$2:0)}')}"
    disk="${DISK_PCT:-$(df / | awk 'NR==2{gsub(/%/,"",$5);print $5}')}"
    up="$(human_duration "$(cut -d. -f1 /proc/uptime)")"

    out="📊 <b>${title} — $(hostname)</b>\n"
    out+="🗓️ $(date '+%Y-%m-%d %H:%M')\n"
    out+="🖥️ Uptime ${up} | CPU ${cpu}% | RAM ${mem}% | Disk ${disk}%\n"
    out+="────────────────────\n"

    local -a t; mapfile -t t < <(list_tunnels)
    if [[ ${#t[@]} -eq 0 ]]; then
        out+="No tunnels configured.\n"
    else
        local n active
        for n in "${t[@]}"; do
            load_tunnel "$n"; state_load "$n"
            active="🔴"; svc_is_active "$n" && active="🟢"
            out+="${active} <b>${n}</b> (${TUN[PROTOCOL]}/${TUN[ROLE]})\n"
            out+="   ↓ $(human_bytes "${ST[RX_BYTES]:-0}")  ↑ $(human_bytes "${ST[TX_BYTES]:-0}")\n"
            out+="   peak ↓ $(human_bytes "${ST[PEAK_RX_RATE]:-0}")/s ↑ $(human_bytes "${ST[PEAK_TX_RATE]:-0}")/s\n"
            out+="   latency ${ST[LATENCY_MS]:-?}ms  loss ${ST[LOSS_PCT]:-?}%\n"
        done
    fi
    printf '%b' "$out"
}

# report_send PERIOD — build + deliver to Telegram (and log).
report_send() {
    local period="${1:-daily}" body
    body="$(report_build "$period")"
    if tg_enabled; then
        tg_send "$body" && log_ok "Sent $period report to Telegram." || log_warn "Failed to send $period report."
    else
        log_info "$period report generated (Telegram disabled)."
    fi
    # Reset peak counters at the start of each new daily cycle.
    if [[ "$period" == daily ]]; then
        local n
        while read -r n; do
            [[ -n "$n" ]] || continue
            state_set "$n" PEAK_RX_RATE 0 PEAK_TX_RATE 0
        done < <(list_tunnels)
    fi
}

# report_show PERIOD — print report to the terminal (strip simple HTML tags).
report_show() {
    report_build "${1:-daily}" | sed -e 's/<[^>]*>//g'
    echo
}
