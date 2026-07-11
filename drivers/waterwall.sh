#!/usr/bin/env bash
# drivers/waterwall.sh — WaterWall (radkesvat/WaterWall) transport driver.
#
# WaterWall is a high-performance C++ network core configured as a node graph
# (core.json -> config.json). It is extremely flexible; here we generate one
# proven, simple reverse-tunnel profile:
#
#   client (Iran):  TcpListener(:user_port) -> ObfuscatorClient(xor) -> TcpConnector(foreign:tunnel_port)
#   server (foreign): TcpListener(:tunnel_port) -> ObfuscatorServer(xor) -> TcpConnector(127.0.0.1:target_port)
#
# The XOR obfuscator masks the stream so Iran's DPI does not recognise it. Iran
# dials out (Iran->foreign). For full custom graphs, drop your own config.json
# into the tunnel's directory (see docs) — the tool still manages the binary,
# service, persistence and monitoring.
#
# TUN keys: WW_ROLE(client|server) WW_PORT WW_KEY REMOTE_IP
#           WW_USER_PORT(client) WW_TARGET_PORT(server)

: "${WATERWALL_REPO:=radkesvat/WaterWall}"
: "${WATERWALL_DEFAULT_VERSION:=v1.46.3}"
: "${TM_WATERWALL_DIR:=$TM_CONFIG_DIR/waterwall}"
# old-cpu builds avoid AVX and run on virtually any VPS; override with e.g. "x64".
: "${WATERWALL_VARIANT:=old-cpu}"

ww_bin() { printf '%s/Waterwall' "$TM_BIN_DIR"; }
ww_dir() { printf '%s/%s' "$TM_WATERWALL_DIR" "$1"; }

ww_latest_version() {
    local v
    v="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${WATERWALL_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)"
    printf '%s' "${v:-$WATERWALL_DEFAULT_VERSION}"
}

ww_asset() {
    local arch="$1" v="$WATERWALL_VARIANT"
    case "$arch" in
        amd64) [[ "$v" == old-cpu ]] && echo "Waterwall-linux-gcc-x64-old-cpu.zip" || echo "Waterwall-linux-gcc-x64.zip" ;;
        arm64) [[ "$v" == old-cpu ]] && echo "Waterwall-linux-gcc-arm64-old-cpu.zip" || echo "Waterwall-linux-gcc-arm64.zip" ;;
        *) echo "" ;;
    esac
}

ww_ensure_binary() {
    local bin; bin="$(ww_bin)"
    is_elf "$bin" && return 0
    [[ -e "$bin" ]] && rm -f "$bin"
    local arch; arch="$(cpu_arch)"
    local asset; asset="$(ww_asset "$arch")"
    [[ -n "$asset" ]] || { log_error "WaterWall supports amd64/arm64 only (got $(uname -m))."; return 1; }
    have unzip || { log_error "unzip is required for WaterWall (apt install unzip)."; return 1; }
    local ver url tmp
    ver="${WATERWALL_VERSION:-$(ww_latest_version)}"
    url="https://github.com/${WATERWALL_REPO}/releases/download/${ver}/${asset}"
    tmp="$(mktemp -d)"
    log_info "Downloading WaterWall ${ver} (${asset})…"
    if ! curl -fsSL --max-time 180 --retry 3 --retry-delay 5 -o "$tmp/w.zip" "$url"; then
        rm -rf "$tmp"; log_error "Download failed: $url"; return 1
    fi
    unzip -o -q "$tmp/w.zip" -d "$tmp" 2>/dev/null || { rm -rf "$tmp"; log_error "unzip failed"; return 1; }
    local f found=""
    while IFS= read -r f; do is_elf "$f" && { found="$f"; break; }; done < <(find "$tmp" -type f -iname 'Waterwall*' | sort)
    [[ -n "$found" ]] || while IFS= read -r f; do is_elf "$f" && { found="$f"; break; }; done < <(find "$tmp" -type f | sort)
    [[ -n "$found" ]] || { rm -rf "$tmp"; log_error "no Waterwall binary in archive"; return 1; }
    mkdir -p "$TM_BIN_DIR"; install -m 0755 "$found" "$bin"; rm -rf "$tmp"
    log_ok "Installed WaterWall binary -> $bin"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
waterwall_wizard() {
    local def_role="client"; [[ "${TUN[ROLE]}" == foreign ]] && def_role="server"
    local role
    ask_menu role "WaterWall role for THIS server (client = users connect here + dials out; server = exit)" \
        "$def_role" "$([[ "$def_role" == server ]] && echo client || echo server)"
    TUN[WW_ROLE]="$role"

    ask_valid TUN[WW_PORT] "Tunnel port (server listens / client connects)" is_port 8443
    # Obfuscation is OFF by default: xray/VLESS-Reality already camouflages itself,
    # so a transparent tunnel is the reliable choice. Enable XOR only for carrying
    # non-camouflaged (plain) traffic.
    TUN[WW_OBFUSCATE]=no; TUN[WW_KEY]=0
    if confirm "Add XOR obfuscation? (leave OFF for xray/Reality — it self-camouflages)" no; then
        TUN[WW_OBFUSCATE]=yes
        ask_valid TUN[WW_KEY] "Obfuscation XOR key 1-255 (MUST match the other side)" _ww_is_key "$(( (RANDOM % 254) + 1 ))"
    fi

    if [[ "$role" == client ]]; then
        ask_valid TUN[REMOTE_IP] "Server (foreign) public IP" is_ipv4
        ask_valid TUN[WW_USER_PORT] "Local port users connect to here" is_port 443
    else
        ask_valid TUN[WW_TARGET_PORT] "Local service port to forward to (e.g. xray)" is_port 443
    fi
}

_ww_is_key() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 255 )); }

waterwall_validate() {
    is_port "${TUN[WW_PORT]:-}" || { log_error "invalid tunnel port"; return 1; }
    if [[ "${TUN[WW_OBFUSCATE]:-no}" == yes ]]; then
        _ww_is_key "${TUN[WW_KEY]:-}" || { log_error "XOR key must be 1-255"; return 1; }
    fi
    if [[ "${TUN[WW_ROLE]}" == client ]]; then
        is_ipv4 "${TUN[REMOTE_IP]:-}" || { log_error "invalid server IP"; return 1; }
        is_port "${TUN[WW_USER_PORT]:-}" || { log_error "invalid user port"; return 1; }
    else
        is_port "${TUN[WW_TARGET_PORT]:-}" || { log_error "invalid target port"; return 1; }
    fi
    return 0
}

ww_generate_config() {
    local dir; dir="$(ww_dir "${TUN[NAME]}")"
    mkdir -p "$dir/log"
    printf '{ "configs": ["config.json"] }\n' >"$dir/core.json"
    local cfg="$dir/config.json" tmp; tmp="$(mktemp)"
    # Bring-your-own graph: if you drop a hand-crafted WaterWall config at
    # <dir>/custom.json (e.g. a Reality/encryption profile), it is used verbatim
    # and the built-in simple-tunnel generator is skipped.
    if [[ -f "$dir/custom.json" ]]; then
        install -m 600 "$dir/custom.json" "$cfg"
        log_info "WaterWall '${TUN[NAME]}' using custom.json"
        rm -f "$tmp"; return 0
    fi

    # Build the listener + optional obfuscator + connector chain.
    local in_addr in_port out_addr out_port name obf_type in_next="out" obf_node=""
    if [[ "${TUN[WW_ROLE]}" == client ]]; then
        name="${TUN[NAME]}-client"; obf_type="ObfuscatorClient"
        in_addr="0.0.0.0";   in_port="${TUN[WW_USER_PORT]}"
        out_addr="${TUN[REMOTE_IP]}"; out_port="${TUN[WW_PORT]}"
    else
        name="${TUN[NAME]}-server"; obf_type="ObfuscatorServer"
        in_addr="0.0.0.0";   in_port="${TUN[WW_PORT]}"
        out_addr="127.0.0.1"; out_port="${TUN[WW_TARGET_PORT]}"
    fi
    if [[ "${TUN[WW_OBFUSCATE]:-no}" == yes ]]; then
        in_next="obf"
        obf_node="    { \"name\": \"obf\", \"type\": \"${obf_type}\", \"settings\": { \"method\": \"xor\", \"xor_key\": ${TUN[WW_KEY]}, \"skip\": \"none\", \"tls_record_header\": false }, \"next\": \"out\" },
"
    fi
    cat >"$tmp" <<EOF
{
  "name": "${name}",
  "nodes": [
    { "name": "in",  "type": "TcpListener",  "settings": { "address": "${in_addr}", "port": ${in_port}, "nodelay": true }, "next": "${in_next}" },
${obf_node}    { "name": "out", "type": "TcpConnector", "settings": { "address": "${out_addr}", "port": ${out_port}, "nodelay": true } }
  ]
}
EOF
    chmod 600 "$tmp"; mv -f "$tmp" "$cfg"
    log_debug "wrote waterwall config $cfg"
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
waterwall_up() {
    ww_ensure_binary || return 1
    ww_generate_config
    log_ok "WaterWall '${TUN[NAME]}' prepared"
}
waterwall_down() { return 0; }

waterwall_render_unit() {
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (WaterWall ${TUN[WW_ROLE]})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Do NOT use WorkingDirectory here: systemd applies it BEFORE ExecStartPre, but
# ExecStartPre (__up) is what creates this directory. Instead cd inside ExecStart
# after the directory and binary have been prepared.
ExecStartPre=${TM_CTL} __up ${TUN[NAME]}
ExecStart=/usr/bin/env bash -c 'cd "$(ww_dir "${TUN[NAME]}")" && exec "$(ww_bin)"'
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

waterwall_health() { systemctl is-active --quiet "$(unit_name "$1")"; }
waterwall_sample() { printf '0 0'; }

waterwall_status() {
    ui_kv "Role"      "${TUN[WW_ROLE]}"
    if [[ "${TUN[WW_OBFUSCATE]:-no}" == yes ]]; then ui_kv "Obfuscator" "xor key=${TUN[WW_KEY]}"; else ui_kv "Obfuscator" "off (transparent)"; fi
    if [[ "${TUN[WW_ROLE]}" == client ]]; then
        ui_kv "Listen"  "0.0.0.0:${TUN[WW_USER_PORT]} → ${TUN[REMOTE_IP]}:${TUN[WW_PORT]}"
    else
        ui_kv "Listen"  "0.0.0.0:${TUN[WW_PORT]} → 127.0.0.1:${TUN[WW_TARGET_PORT]}"
    fi
    if is_elf "$(ww_bin)"; then ui_kv "Binary" "$(ww_bin)"; else ui_kv "Binary" "$(status_dot down) not installed"; fi
}
