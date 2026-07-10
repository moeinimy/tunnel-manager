#!/usr/bin/env bash
# modules/telegram.sh — optional Telegram notifications + command bot.
# The whole project works without Telegram; every notify call is a no-op unless
# a bot token and chat id are configured.

TG_API="https://api.telegram.org"

# tg_load — read telegram.conf into the environment (best-effort).
tg_load() {
    [[ -f "$TM_TELEGRAM_FILE" ]] && . "$TM_TELEGRAM_FILE"
    return 0
}

# tg_enabled — true only if fully configured.
tg_enabled() {
    tg_load
    [[ "${TG_ENABLED:-no}" == yes && -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]
}

# tg_send TEXT [CHAT_ID] — send an HTML message (returns curl status).
tg_send() {
    local text="$1" chat="${2:-$TG_CHAT_ID}"
    [[ -n "${TG_BOT_TOKEN:-}" && -n "$chat" ]] || return 1
    curl -fsS --max-time 20 \
        -d "chat_id=${chat}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" \
        "${TG_API}/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1
}

# tg_notify TEXT — fire-and-forget notification; never fails the caller.
tg_notify() {
    tg_enabled || return 0
    tg_send "$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------
tg_configure() {
    require_root
    ui_title "Telegram configuration"
    tg_load
    local token chat
    ask token "Bot token (from @BotFather)" "${TG_BOT_TOKEN:-}"
    ask chat  "Chat ID (numeric; from @userinfobot)" "${TG_CHAT_ID:-}"
    if [[ -z "$token" || -z "$chat" ]]; then
        log_warn "Both token and chat id are required; leaving Telegram disabled."
        return 1
    fi
    umask 077
    cat >"$TM_TELEGRAM_FILE" <<EOF
# Managed by Tunnel Manager. Keep this file private (chmod 600).
TG_ENABLED=yes
TG_BOT_TOKEN=$token
TG_CHAT_ID=$chat
EOF
    chmod 600 "$TM_TELEGRAM_FILE"
    tg_load
    if tg_send "✅ <b>Tunnel Manager</b> connected on $(hostname)."; then
        log_ok "Telegram configured and test message sent."
        systemctl enable --now tm-bot.service >/dev/null 2>&1 || \
            log_warn "Could not start tm-bot.service (is it installed?)."
    else
        log_error "Test message failed — check the token and chat id."
        return 1
    fi
}

tg_disable() {
    require_root
    if [[ -f "$TM_TELEGRAM_FILE" ]]; then
        sed -i 's/^TG_ENABLED=.*/TG_ENABLED=no/' "$TM_TELEGRAM_FILE"
    fi
    systemctl disable --now tm-bot.service >/dev/null 2>&1 || true
    log_ok "Telegram disabled."
}

# ---------------------------------------------------------------------------
# Command bot (long-poll). Runs as tm-bot.service.
# ---------------------------------------------------------------------------
tg_bot_run() {
    tg_enabled || { log_warn "Telegram not configured; bot exiting."; return 0; }
    log_info "Telegram bot started."
    local offset=0 resp n i chat text
    while true; do
        resp="$(curl -fsS --max-time 60 \
            "${TG_API}/bot${TG_BOT_TOKEN}/getUpdates?timeout=50&offset=${offset}" 2>/dev/null)" || { sleep 3; continue; }
        n="$(printf '%s' "$resp" | jq '.result | length' 2>/dev/null || echo 0)"
        [[ "$n" =~ ^[0-9]+$ ]] || { sleep 2; continue; }
        for (( i=0; i<n; i++ )); do
            offset="$(( $(printf '%s' "$resp" | jq -r ".result[$i].update_id") + 1 ))"
            chat="$(printf '%s' "$resp" | jq -r ".result[$i].message.chat.id // empty")"
            text="$(printf '%s' "$resp" | jq -r ".result[$i].message.text // empty")"
            [[ -n "$text" ]] || continue
            if [[ "$chat" != "$TG_CHAT_ID" ]]; then
                tg_send "⛔ Unauthorized." "$chat"
                continue
            fi
            tg_bot_dispatch "$text"
        done
    done
}

# tg_bot_dispatch "COMMAND ARGS" — handle one incoming command.
tg_bot_dispatch() {
    local line="$1" cmd arg
    cmd="${line%% *}"; cmd="${cmd%%@*}"   # strip @botname
    arg="${line#"$cmd"}"; arg="${arg# }"
    case "$cmd" in
        /start|/help)
            tg_send "$(tg_help_text)" ;;
        /status|/tunnels)
            tg_send "$(tg_report_tunnels)" ;;
        /system)
            tg_send "$(tg_report_system)" ;;
        /bandwidth)
            tg_send "$(tg_report_bandwidth)" ;;
        /report)
            tg_send "$(report_build daily)" ;;
        /logs)
            local body; body="$(journalctl -u "$(unit_name "$arg")" -n 20 --no-pager 2>/dev/null | tail -c 3500)"
            tg_send "<b>Logs ${arg}</b>\n<pre>${body:-no logs}</pre>" ;;
        /restart)
            if [[ -n "$arg" ]] && tunnel_exists "$arg"; then
                tunnel_restart "$arg" && tg_send "🔄 Restarted <b>$arg</b>." || tg_send "❌ Restart of <b>$arg</b> failed."
            else
                tg_send "Usage: /restart &lt;tunnel-name&gt;" ; fi ;;
        /reboot)
            tg_send "♻️ Rebooting <b>$(hostname)</b> in 5s…"; ( sleep 5; systemctl reboot ) & ;;
        *)
            tg_send "Unknown command. Send /help." ;;
    esac
}

tg_help_text() {
    cat <<'EOF'
<b>Tunnel Manager bot</b>
/status – tunnels overview
/tunnels – same as status
/system – CPU / RAM / disk / uptime
/bandwidth – live RX/TX per tunnel
/report – full daily report
/logs &lt;name&gt; – recent logs for a tunnel
/restart &lt;name&gt; – restart a tunnel
/reboot – reboot this server
/help – this message
EOF
}

# --- Bot report builders (plain-ish HTML) --------------------------------
tg_report_tunnels() {
    local out="<b>Tunnels on $(hostname)</b>\n" n active
    local -a t; mapfile -t t < <(list_tunnels)
    [[ ${#t[@]} -eq 0 ]] && { printf 'No tunnels configured.'; return; }
    for n in "${t[@]}"; do
        load_tunnel "$n"
        active="🔴"; svc_is_active "$n" && active="🟢"
        out+="${active} <b>${n}</b> — ${TUN[PROTOCOL]}/${TUN[ROLE]} → ${TUN[REMOTE_IP]:-?}\n"
    done
    printf '%b' "$out"
}

tg_report_system() {
    local load mem disk up
    load="$(cut -d' ' -f1-3 /proc/loadavg)"
    mem="$(free -m | awk '/^Mem:/{printf "%d/%d MiB", $3, $2}')"
    disk="$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    up="$(human_duration "$(cut -d. -f1 /proc/uptime)")"
    printf '<b>System — %s</b>\nUptime: %s\nLoad: %s\nRAM: %s\nDisk /: %s' \
        "$(hostname)" "$up" "$load" "$mem" "$disk"
}

tg_report_bandwidth() {
    local out="<b>Bandwidth</b>\n" n
    local -a t; mapfile -t t < <(list_tunnels)
    for n in "${t[@]}"; do
        state_load "$n"
        out+="<b>${n}</b>: ↓ $(human_bytes "${ST[RX_RATE]:-0}")/s ↑ $(human_bytes "${ST[TX_RATE]:-0}")/s | total ↓ $(human_bytes "${ST[RX_BYTES]:-0}") ↑ $(human_bytes "${ST[TX_BYTES]:-0}")\n"
    done
    printf '%b' "$out"
}
