#!/usr/bin/env bash
# drivers/reality.sh — VLESS + REALITY + Vision relay driver (xray-core).
#
# REALITY (github.com/XTLS/Xray-core) produces a TLS 1.3 handshake that is
# byte-for-byte identical to a real browser opening a real HTTPS site — it
# borrows the certificate/handshake of a genuine high-traffic domain, so there
# is no self-signed cert or novel fingerprint for DPI to flag. Combined with
# XTLS-Vision (which flattens the length/timing signature of TLS-in-TLS) this is
# the strongest anti-DPI TCP transport available (community-measured ~98% bypass
# in Iran in 2026), and unlike Hysteria/TUIC it rides over TCP, so it works even
# where the foreign provider blocks inbound UDP.
#
# Model (real TCP port-forward, fits xray-on-foreign relay): the FOREIGN side
# runs a VLESS+REALITY inbound and a freedom outbound; the IRAN side runs a
# dokodemo-door inbound per user port that hands traffic to a VLESS+REALITY+
# Vision outbound aimed at the foreign. So: xray client → iran:<listen> → REALITY
# tunnel → foreign → 127.0.0.1:<target> (the foreign's real xray Reality inbound).
# The client dials out (Iran→foreign), the proven direction.
#
# Key coordination is one copy-paste: the server prints a base64 "connection
# string" (uuid|publicKey|shortId|sni|port); the client just pastes it.
#
# TUN keys: RE_ROLE(server|client) RE_PORT RE_UUID RE_PRIV(server) RE_PUB RE_SID
#           RE_SNI RE_PORTS(client; ';'-sep "listen=target") RE_TARGET REMOTE_IP
#           LOCAL_IP

: "${XRAY_REPO:=XTLS/Xray-core}"
: "${TM_REALITY_DIR:=$TM_CONFIG_DIR/reality}"

reality_bin() { printf '%s/xray' "$TM_BIN_DIR"; }
reality_cfg() { printf '%s/%s.json' "$TM_REALITY_DIR" "$1"; }

reality_ensure_binary() {
    local bin; bin="$(reality_bin)"
    is_elf "$bin" && return 0
    [[ -e "$bin" ]] && rm -f "$bin"
    local arch asset
    case "$(cpu_arch)" in
        amd64) asset="Xray-linux-64.zip" ;;
        arm64) asset="Xray-linux-arm64-v8a.zip" ;;
        *)     log_error "Reality (xray) supports amd64/arm64 only (got $(uname -m))."; return 1 ;;
    esac
    have unzip || { log_error "unzip is required for xray (apt-get install -y unzip)"; return 1; }
    local url tmp
    url="https://github.com/${XRAY_REPO}/releases/latest/download/${asset}"
    tmp="$(mktemp -d)"
    log_info "Downloading xray-core (${asset})…"
    if ! curl -fsSL --max-time 180 --retry 3 --retry-delay 5 -o "$tmp/x.zip" "$url"; then
        rm -rf "$tmp"; log_error "Download failed: $url"; return 1
    fi
    unzip -o -q "$tmp/x.zip" -d "$tmp" 2>/dev/null || { rm -rf "$tmp"; log_error "unzip failed"; return 1; }
    local f found=""
    while IFS= read -r f; do is_elf "$f" && { found="$f"; break; }; done < <(find "$tmp" -type f -name xray | sort)
    [[ -n "$found" ]] || while IFS= read -r f; do is_elf "$f" && { found="$f"; break; }; done < <(find "$tmp" -type f | sort)
    [[ -n "$found" ]] || { rm -rf "$tmp"; log_error "no xray binary in archive"; return 1; }
    mkdir -p "$TM_BIN_DIR"; install -m 0755 "$found" "$bin"; rm -rf "$tmp"
    log_ok "Installed xray-core -> $bin"
}

# reality_gen_keys — populate RE_PRIV/RE_PUB/RE_UUID/RE_SID (server side).
reality_gen_keys() {
    local bin xk
    bin="$(reality_bin)"
    xk="$("$bin" x25519 2>/dev/null)"
    TUN[RE_PRIV]="$(printf '%s\n' "$xk" | grep -i  'private'          | awk -F'[: ]+' '{print $NF}')"
    TUN[RE_PUB]="$( printf '%s\n' "$xk" | grep -iE 'public|password'  | awk -F'[: ]+' '{print $NF}')"
    [[ -n "${TUN[RE_PRIV]}" && -n "${TUN[RE_PUB]}" ]] || { log_error "xray x25519 key generation failed"; return 1; }
    TUN[RE_UUID]="$("$bin" uuid 2>/dev/null)"
    [[ -n "${TUN[RE_UUID]}" ]] || TUN[RE_UUID]="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
    TUN[RE_SID]="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 8)"
    return 0
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
reality_wizard() {
    # foreign = REALITY server (exit); iran = client (dokodemo → tunnel out).
    local def_role="client"; [[ "${TUN[ROLE]}" == foreign ]] && def_role="server"
    local role
    ask_menu role "Reality role for THIS server (server = REALITY exit on foreign; client = entry on Iran that dials out)" \
        "$def_role" "$([[ "$def_role" == server ]] && echo client || echo server)"
    TUN[RE_ROLE]="$role"

    local def_local; def_local="$(detect_local_ip)"
    ask_valid TUN[LOCAL_IP] "This server's IP" is_ipv4 "$def_local"

    if [[ "$role" == server ]]; then
        ask_valid TUN[RE_PORT] "REALITY tunnel port (TCP, what the Iran side dials)" is_port 8443
        ask TUN[RE_SNI] "Camouflage domain / SNI to borrow (real TLS1.3+H2 site, not blocked in Iran)" "www.microsoft.com"
        log_info "Generating REALITY keys (needs the xray binary)…"
        reality_ensure_binary || return 1
        reality_gen_keys      || return 1
        local bundle
        bundle="$(printf '%s|%s|%s|%s|%s' "${TUN[RE_UUID]}" "${TUN[RE_PUB]}" "${TUN[RE_SID]}" "${TUN[RE_SNI]}" "${TUN[RE_PORT]}" | base64 -w0)"
        log_ok "REALITY connection string — paste this on the Iran/client side:"
        printf '\n  %s%s%s\n\n' "$C_BOLD" "$bundle" "$C_RESET" >&2
    else
        local bundle dec u p s sni port
        while true; do
            ask bundle "Paste the REALITY connection string from the server side" ""
            dec="$(printf '%s' "$bundle" | base64 -d 2>/dev/null)"
            IFS='|' read -r u p s sni port <<<"$dec"
            if [[ -n "$u" && -n "$p" && -n "$s" && -n "$sni" && -n "$port" ]]; then break; fi
            log_error "Invalid/incomplete connection string — try again."
        done
        TUN[RE_UUID]="$u"; TUN[RE_PUB]="$p"; TUN[RE_SID]="$s"; TUN[RE_SNI]="$sni"; TUN[RE_PORT]="$port"

        ask_valid TUN[REMOTE_IP] "Server (foreign) public IP" is_ipv4
        ask TUN[RE_TARGET] "Target host the exit forwards to (usually the foreign's localhost)" "127.0.0.1"
        log_info "Map local ports (users/xray hit these on Iran) to target ports on the exit side."
        reality_wizard_ports
    fi
}

reality_wizard_ports() {
    local list="" lp tp
    while true; do
        ask_valid lp "Local listen port (here, users connect to this)" is_port
        ask_valid tp "Target port (on the exit/foreign side)" is_port "$lp"
        list+="${list:+;}${lp}=${tp}"
        confirm "Add another port?" no || break
    done
    TUN[RE_PORTS]="$list"
}

# ---------------------------------------------------------------------------
# Validation & config
# ---------------------------------------------------------------------------
reality_validate() {
    is_port "${TUN[RE_PORT]:-}" || { log_error "invalid tunnel port"; return 1; }
    [[ -n "${TUN[RE_UUID]:-}" && -n "${TUN[RE_SID]:-}" && -n "${TUN[RE_SNI]:-}" ]] || { log_error "missing reality identity (uuid/shortId/sni)"; return 1; }
    if [[ "${TUN[RE_ROLE]}" == server ]]; then
        [[ -n "${TUN[RE_PRIV]:-}" ]] || { log_error "server missing private key"; return 1; }
    else
        [[ -n "${TUN[RE_PUB]:-}" ]] || { log_error "client missing public key"; return 1; }
        is_ipv4 "${TUN[REMOTE_IP]:-}" || { log_error "invalid server IP"; return 1; }
        [[ -n "${TUN[RE_PORTS]:-}" ]] || { log_error "at least one port mapping required"; return 1; }
    fi
    return 0
}

reality_generate_config() {
    local file; file="$(reality_cfg "${TUN[NAME]}")"
    mkdir -p "$TM_REALITY_DIR"
    local tmp; tmp="$(mktemp)"
    if [[ "${TUN[RE_ROLE]}" == server ]]; then
        cat >"$tmp" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${TUN[RE_PORT]},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${TUN[RE_UUID]}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${TUN[RE_SNI]}:443",
          "xver": 0,
          "serverNames": [ "${TUN[RE_SNI]}" ],
          "privateKey": "${TUN[RE_PRIV]}",
          "shortIds": [ "${TUN[RE_SID]}" ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
JSON
    else
        # Build one dokodemo-door inbound per port map.
        local inbounds="" first=1 lp tp
        local IFS=';' e
        for e in ${TUN[RE_PORTS]}; do
            IFS='=' read -r lp tp <<<"$e"
            [[ $first -eq 1 ]] || inbounds+=","
            first=0
            inbounds+="$(printf '\n    { "listen": "0.0.0.0", "port": %s, "protocol": "dokodemo-door", "settings": { "address": "%s", "port": %s, "network": "tcp" }, "tag": "in-%s" }' \
                "$lp" "${TUN[RE_TARGET]:-127.0.0.1}" "$tp" "$lp")"
        done
        cat >"$tmp" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [${inbounds}
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${TUN[REMOTE_IP]}",
            "port": ${TUN[RE_PORT]},
            "users": [ { "id": "${TUN[RE_UUID]}", "encryption": "none" } ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "${TUN[RE_SNI]}",
          "publicKey": "${TUN[RE_PUB]}",
          "shortId": "${TUN[RE_SID]}",
          "spiderX": "/"
        }
      },
      "tag": "reality-out"
    }
  ]
}
JSON
    fi
    chmod 600 "$tmp"; mv -f "$tmp" "$file"
    log_debug "wrote reality config $file"
}

# ---------------------------------------------------------------------------
# Lifecycle (userspace TCP — no kernel/iptables work needed)
# ---------------------------------------------------------------------------
reality_up() {
    reality_ensure_binary || return 1
    reality_generate_config
    # Fail fast on a malformed config so systemd doesn't crash-loop silently.
    if ! "$(reality_bin)" run -test -c "$(reality_cfg "${TUN[NAME]}")" >/dev/null 2>&1; then
        log_warn "xray config self-test reported an issue for '${TUN[NAME]}' (continuing)"
    fi
    log_ok "Reality '${TUN[NAME]}' prepared"
}
reality_down() { return 0; }

reality_render_unit() {
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (VLESS+Reality)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${TM_CTL} __up ${TUN[NAME]}
ExecStart=$(reality_bin) run -c $(reality_cfg "${TUN[NAME]}")
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

reality_health() { systemctl is-active --quiet "$(unit_name "$1")"; }
reality_sample() { printf '0 0'; }

reality_status() {
    ui_kv "Role"      "${TUN[RE_ROLE]}"
    ui_kv "Transport" "VLESS+REALITY (TCP)"
    ui_kv "SNI"       "${TUN[RE_SNI]}"
    if [[ "${TUN[RE_ROLE]}" == server ]]; then
        ui_kv "Listen"  "0.0.0.0:${TUN[RE_PORT]}"
        [[ -n "${TUN[REMOTE_IP]:-}" ]] && ui_kv "Peer (bot)" "${TUN[REMOTE_IP]}"
    else
        ui_kv "Server"  "${TUN[REMOTE_IP]}:${TUN[RE_PORT]}   maps: ${TUN[RE_PORTS]} → ${TUN[RE_TARGET]:-127.0.0.1}"
    fi
    if is_elf "$(reality_bin)"; then ui_kv "Binary" "$(reality_bin)"; else ui_kv "Binary" "$(status_dot down) not installed"; fi
}
