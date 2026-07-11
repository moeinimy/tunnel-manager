#!/usr/bin/env bash
# modules/telegram.sh — optional Telegram notifications + interactive command bot
# with inline (glass) keyboards. The project works fully without Telegram; every
# notify call is a no-op unless a bot token and chat id are configured.

TG_API="https://api.telegram.org"

# tg_load — read telegram.conf into the environment (best-effort).
tg_load() {
    [[ -f "$TM_TELEGRAM_FILE" ]] && . "$TM_TELEGRAM_FILE"
    return 0
}

tg_enabled() {
    tg_load
    [[ "${TG_ENABLED:-no}" == yes && -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]
}

# tg_send TEXT [CHAT] — plain HTML message.
tg_send() {
    local text="$1" chat="${2:-$TG_CHAT_ID}"
    [[ -n "${TG_BOT_TOKEN:-}" && -n "$chat" ]] || return 1
    curl -fsS --max-time 20 \
        -d "chat_id=${chat}" -d "parse_mode=HTML" -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" \
        "${TG_API}/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1
}

# tg_send_kb TEXT KEYBOARD_JSON [CHAT] — message with an inline keyboard.
tg_send_kb() {
    local text="$1" kb="$2" chat="${3:-$TG_CHAT_ID}"
    [[ -n "${TG_BOT_TOKEN:-}" && -n "$chat" ]] || return 1
    curl -fsS --max-time 20 \
        -d "chat_id=${chat}" -d "parse_mode=HTML" -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" \
        --data-urlencode "reply_markup=${kb}" \
        "${TG_API}/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1
}

# tg_answer_callback ID [TEXT] — acknowledge a button tap (stops the spinner).
tg_answer_callback() {
    local cid="$1" text="${2:-}"
    curl -fsS --max-time 10 \
        -d "callback_query_id=${cid}" --data-urlencode "text=${text}" \
        "${TG_API}/bot${TG_BOT_TOKEN}/answerCallbackQuery" >/dev/null 2>&1
}

# tg_notify TEXT — fire-and-forget notification; never fails the caller.
tg_notify() {
    tg_enabled || return 0
    tg_send "$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Configuration
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
        tg_send_kb "Tap a button to begin:" "$(tg_kb_main)" >/dev/null 2>&1 || true
        systemctl enable --now tm-bot.service >/dev/null 2>&1 || \
            log_warn "Could not start tm-bot.service (is it installed?)."
    else
        log_error "Test message failed — send /start to your bot first, then retry."
        return 1
    fi
}

tg_disable() {
    require_root
    [[ -f "$TM_TELEGRAM_FILE" ]] && sed -i 's/^TG_ENABLED=.*/TG_ENABLED=no/' "$TM_TELEGRAM_FILE"
    systemctl disable --now tm-bot.service >/dev/null 2>&1 || true
    log_ok "Telegram disabled."
}

# ---------------------------------------------------------------------------
# Inline keyboards
# ---------------------------------------------------------------------------
tg_kb_main() {
    printf '%s' '{"inline_keyboard":[[{"text":"📊 Status","callback_data":"status"},{"text":"🖥 System","callback_data":"system"}],[{"text":"📈 Bandwidth","callback_data":"bandwidth"},{"text":"📅 Usage","callback_data":"usage"}],[{"text":"🚇 Tunnels","callback_data":"tunnels"},{"text":"🔄 Restart","callback_data":"restart_menu"}],[{"text":"📋 Report","callback_data":"report"},{"text":"🌐 Peers","callback_data":"peers"}],[{"text":"♻️ Reboot","callback_data":"reboot_confirm"}]]}'
}

# tg_kb_tunnels ACTION — one button per tunnel with callback "ACTION:name".
tg_kb_tunnels() {
    local action="$1" name rows=""
    while read -r name; do
        [[ -n "$name" ]] || continue
        rows+="${rows:+,}[{\"text\":\"🚇 ${name}\",\"callback_data\":\"${action}:${name}\"}]"
    done < <(list_tunnels)
    rows+="${rows:+,}[{\"text\":\"« Back\",\"callback_data\":\"menu\"}]"
    printf '{"inline_keyboard":[%s]}' "$rows"
}

tg_kb_peers() {
    local name rows=""
    while IFS=$'\t' read -r name _; do
        [[ -n "$name" ]] || continue
        rows+="${rows:+,}[{\"text\":\"🌐 ${name}\",\"callback_data\":\"peer:${name}\"}]"
    done < <(peer_list 2>/dev/null)
    rows+="${rows:+,}[{\"text\":\"« Back\",\"callback_data\":\"menu\"}]"
    printf '{"inline_keyboard":[%s]}' "$rows"
}

# ---------------------------------------------------------------------------
# Bot loop (handles both text commands and button callbacks)
# ---------------------------------------------------------------------------
tg_bot_run() {
    tg_enabled || { log_warn "Telegram not configured; bot exiting."; return 0; }
    log_info "Telegram bot started."
    local offset=0 resp n i chat text cb_id cb_chat cb_data
    while true; do
        resp="$(curl -fsS --max-time 60 \
            "${TG_API}/bot${TG_BOT_TOKEN}/getUpdates?timeout=50&offset=${offset}&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D" 2>/dev/null)" || { sleep 3; continue; }
        n="$(printf '%s' "$resp" | jq '.result | length' 2>/dev/null || echo 0)"
        [[ "$n" =~ ^[0-9]+$ ]] || { sleep 2; continue; }
        for (( i=0; i<n; i++ )); do
            offset="$(( $(printf '%s' "$resp" | jq -r ".result[$i].update_id") + 1 ))"
            cb_id="$(printf '%s' "$resp" | jq -r ".result[$i].callback_query.id // empty")"
            if [[ -n "$cb_id" ]]; then
                cb_chat="$(printf '%s' "$resp" | jq -r ".result[$i].callback_query.message.chat.id // empty")"
                cb_data="$(printf '%s' "$resp" | jq -r ".result[$i].callback_query.data // empty")"
                tg_answer_callback "$cb_id"
                [[ "$cb_chat" == "$TG_CHAT_ID" ]] || { tg_send "⛔ Unauthorized." "$cb_chat"; continue; }
                tg_action "$cb_data" "$cb_chat"
                continue
            fi
            chat="$(printf '%s' "$resp" | jq -r ".result[$i].message.chat.id // empty")"
            text="$(printf '%s' "$resp" | jq -r ".result[$i].message.text // empty")"
            [[ -n "$text" ]] || continue
            [[ "$chat" == "$TG_CHAT_ID" ]] || { tg_send "⛔ Unauthorized." "$chat"; continue; }
            tg_command "$text" "$chat"
        done
    done
}

# tg_command "TEXT" CHAT — map a typed command to an action.
tg_command() {
    local line="$1" chat="$2" cmd arg
    cmd="${line%% *}"; cmd="${cmd%%@*}"
    arg="${line#"$cmd"}"; arg="${arg# }"
    case "$cmd" in
        /start|/menu|/help) tg_action menu "$chat" ;;
        /status|/tunnels)   tg_action status "$chat" ;;
        /system)            tg_action system "$chat" ;;
        /bandwidth)         tg_action bandwidth "$chat" ;;
        /usage|/traffic)    tg_action usage "$chat" ;;
        /report)            tg_action report "$chat" ;;
        /peers)             tg_action peers "$chat" ;;
        /reboot)            tg_action reboot_confirm "$chat" ;;
        /logs)              tg_action "logs:$arg" "$chat" ;;
        /restart)
            if [[ -n "$arg" ]]; then tg_action "restart:$arg" "$chat"
            else tg_action restart_menu "$chat"; fi ;;
        *) tg_send "Unknown command. Send /menu." "$chat" ;;
    esac
}

# tg_action DATA CHAT — the single handler for buttons and commands.
tg_action() {
    local data="$1" chat="$2"
    case "$data" in
        menu)        tg_send_kb "🚇 <b>Tunnel Manager</b> — $(hostname)\nChoose an option:" "$(tg_kb_main)" "$chat" ;;
        status|tunnels) tg_send "$(tg_report_tunnels)" "$chat" ;;
        system)      tg_send "$(tg_report_system)" "$chat" ;;
        bandwidth)   tg_send "$(tg_report_bandwidth)" "$chat" ;;
        usage)       tg_send "$(report_usage)" "$chat" ;;
        report)      tg_send "$(report_build daily)" "$chat" ;;
        peers)       tg_send_kb "🌐 <b>Peers</b> — tap to view a remote server:" "$(tg_kb_peers)" "$chat" ;;
        restart_menu)tg_send_kb "🔄 Pick a tunnel to restart:" "$(tg_kb_tunnels restart)" "$chat" ;;
        restart:*)
            local rn="${data#restart:}"
            if tunnel_exists "$rn"; then
                tunnel_restart "$rn" >/dev/null 2>&1 && tg_send "🔄 Restarted <b>$rn</b>." "$chat" || tg_send "❌ Restart of <b>$rn</b> failed." "$chat"
            else tg_send "No such tunnel: $rn" "$chat"; fi ;;
        logs:*)
            local ln="${data#logs:}" body
            body="$(journalctl -u "$(unit_name "$ln")" -n 20 --no-pager 2>/dev/null | tail -c 3500)"
            tg_send "<b>Logs ${ln}</b>\n<pre>${body:-no logs}</pre>" "$chat" ;;
        peer:*)
            local pn="${data#peer:}"
            tg_send "🌐 Querying <b>$pn</b>…" "$chat"
            tg_send "<b>$pn</b>\n<pre>$(peer_run "$pn" list 2>&1 | tail -c 3500)</pre>" "$chat" ;;
        reboot_confirm)
            tg_send_kb "♻️ Reboot <b>$(hostname)</b>?" '{"inline_keyboard":[[{"text":"✅ Yes, reboot","callback_data":"reboot_yes"},{"text":"« Cancel","callback_data":"menu"}]]}' "$chat" ;;
        reboot_yes)  tg_send "♻️ Rebooting $(hostname) in 3s…" "$chat"; ( sleep 3; systemctl reboot ) & ;;
        *) tg_send "Unknown action." "$chat" ;;
    esac
}

# ---------------------------------------------------------------------------
# Report builders
# ---------------------------------------------------------------------------
tg_report_tunnels() {
    local out="🚇 <b>Tunnels — $(hostname)</b>\n" n active
    local -a t; mapfile -t t < <(list_tunnels)
    [[ ${#t[@]} -eq 0 ]] && { printf 'No tunnels configured.'; return; }
    for n in "${t[@]}"; do
        load_tunnel "$n"; state_load "$n"
        active="🔴"; svc_is_active "$n" && active="🟢"
        out+="${active} <b>${n}</b> ${TUN[PROTOCOL]}/${TUN[ROLE]} → ${TUN[REMOTE_IP]:-?}"
        out+="  (${ST[LATENCY_MS]:-?}ms, loss ${ST[LOSS_PCT]:-?}%)\n"
    done
    printf '%b' "$out"
}

tg_report_system() {
    local load mem disk up cpu
    load="$(cut -d' ' -f1-3 /proc/loadavg)"
    mem="$(free -m | awk '/^Mem:/{printf "%d/%d MiB (%d%%)", $3, $2, ($2?$3*100/$2:0)}')"
    disk="$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    up="$(human_duration "$(cut -d. -f1 /proc/uptime)")"
    [[ -f "$TM_SYS_STATE" ]] && cpu="$(. "$TM_SYS_STATE"; echo "${CPU_PCT:-?}")"
    printf '🖥 <b>System — %s</b>\nUptime: %s\nCPU: %s%%   Load: %s\nRAM: %s\nDisk /: %s' \
        "$(hostname)" "$up" "${cpu:-?}" "$load" "$mem" "$disk"
}

tg_report_bandwidth() {
    local out="📈 <b>Bandwidth — $(hostname)</b>\n" n
    local -a t; mapfile -t t < <(list_tunnels)
    [[ ${#t[@]} -eq 0 ]] && { printf 'No tunnels.'; return; }
    for n in "${t[@]}"; do
        state_load "$n"
        out+="<b>${n}</b>\n"
        out+="  now  ↓ $(human_bytes "${ST[RX_RATE]:-0}")/s  ↑ $(human_bytes "${ST[TX_RATE]:-0}")/s\n"
        out+="  peak ↓ $(human_bytes "${ST[PEAK_RX_RATE]:-0}")/s  ↑ $(human_bytes "${ST[PEAK_TX_RATE]:-0}")/s\n"
        out+="  total ↓ $(human_bytes "${ST[RX_BYTES]:-0}")  ↑ $(human_bytes "${ST[TX_BYTES]:-0}")\n"
    done
    printf '%b' "$out"
}
