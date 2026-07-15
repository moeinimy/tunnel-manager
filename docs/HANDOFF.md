# Session handoff — moeinimy tunnel manager

Continuation notes for a fresh session. Read this first.

## Repo & environment
- **Repo:** https://github.com/moeinimy/tunnel-manager (public). Owner: `moeinimy`.
- **Local working copy:** `D:\claude projects\tunnel-manager` (Windows; use Git Bash / `bash -n` for syntax checks — cannot run Linux tunnel binaries locally).
- **Current version:** 2.0.0 (see `VERSION`).
- **Install on servers:** `bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/tunnel-manager/main/install.sh)`
- **User's test servers:** Iran `188.213.196.205` (client side, runs xray + tunnel clients), foreign `213.182.213.112` (server side, xray on :443). Ubuntu 24 / 22, KVM, amd64.
- **Pushing:** the GitHub push in this project used a PAT the user pasted in chat via an inline credential helper:
  `git -c credential.helper= -c credential.helper='!f(){ echo username=moeinimy; echo "password=$GH_TOKEN"; }; f' push`.
  A new session will NOT have that token — ask the user to provide push access again, or have them push. (Tell them to REVOKE the old PAT — it's exposed in chat history.)

## What works (6 protocols, all tested with the user's real xray)
GRE, Paqet, Backhaul, Rathole, **GOST (mtls)**, FRP. Plus: colorful menu + scriptable CLI, reversible network optimization (auto-applied on install), per-tunnel systemd persistence, GRE relay-all + port forwards, monitor + auto-recovery with TCP-fallback reachability probe, Telegram bot with **inline buttons + persistent keyboard + `/` command menu**, multi-server **auto-peer** (agent over tunnel; GRE inner IP or public REMOTE_IP), **traffic usage over 1h/12h/24h/7d/30d/all**, backup/restore, self-update, universal protocol-aware **Edit Tunnel** (MTU + all ports + secrets).

## Architecture — how to add a protocol driver
A tunnel profile is loaded into the global assoc array `TUN`. Each protocol is a file `drivers/<name>.sh` implementing this contract, with functions named EXACTLY `<name>_<fn>` (the dispatcher calls `${TUN[PROTOCOL]}_<fn>`):
`<name>_wizard`, `<name>_validate`, `<name>_up`, `<name>_down`, `<name>_render_unit`, `<name>_status`, `<name>_health <NAME>`, `<name>_sample <NAME>` (prints "RX TX").
Helpers may use any prefix. **Registration checklist (grep an existing userspace driver like backhaul):**
1. `drivers/<name>.sh` — model on `drivers/backhaul.sh` (binary download + config + systemd) or `gost.sh` (CLI wrapper).
2. `drivers/driver.sh` → add to `TM_SUPPORTED_PROTOCOLS`.
3. `tunnelctl` → add `drivers/<name>.sh` to the source loop.
4. `modules/tunnel.sh` → add to the `ask_menu proto` list (in `tunnel_add`) and the `tunnel_remove` config-cleanup line.
5. `lib/common.sh` → add `TM_<NAME>_DIR` default + to `ensure_dirs`.
6. `install.sh` → add `drivers/<name>.sh` to the update-mode source loop.
7. `uninstall.sh` → add its source line.
8. If it ships as a `.zip`, ensure `unzip` (already in optional deps).
Test: `bash -n`, then source libs+driver and dry-run `<name>_generate_config`/`render_unit`; validate JSON/TOML.

## Hard-won gotchas (DON'T repeat these)
- **Contract fn naming:** must be `<protocol>_<fn>`. A short prefix (e.g. `ww_render_unit`) makes the dispatcher fail with "does not implement".
- **install.sh `--update`:** after switching `TM_HOME` to `/opt/tunnel-manager`, `unset TM_BIN_DIR` before re-sourcing, else units bake the temp `/tmp/.../bin` path → status=127 on restart. (Already fixed; keep it.)
- **systemd:** never point `WorkingDirectory` at a dir that `ExecStartPre` creates — CHDIR runs first and fails. `cd` inside `ExecStart` via `bash -c` instead.
- **Binary install:** validate ELF magic (`is_elf` in common.sh); handle zip vs tar.gz; pick the ELF file, not README.
- **xray/Reality over a tunnel:** plain `tcp` relay gets DPI-reset (~10s stalls / EOF). Persistent **multiplexed + TLS** transport works (GOST `mtls` is the proven one). **Prefer mux/TLS transports.**
- **Testing:** don't use `python3 -m http.server` on 443/9099 — xray already owns those (`Address already in use`), and even a free port only proves forwarding, not xray compat. Test with the user's REAL xray client pointing at `188.213.196.205:<port>`. Use DEBUG logs where a tool has them.
- **GRE:** inbound to Iran is filtered for ICMP (ping shows 100% loss) but TCP works; keyed GRE dropped, keyless works; use `ip tunnel add mode gre` (not `ip link add type gre`). Monitor uses a TCP reachability probe.
- **WaterWall was removed** (v2.0.0): its node graph established the link but corrupted the byte stream on v1.46.3 even transparent — xray never worked through it. Do not re-add without hands-on binary testing.

## NEXT TASK — add these tunnels (user request)
Read each repo's README + source, watch the linked video if helpful, then add a driver following the checklist above. **Use mux where the tool supports it and it doesn't break the tunnel.** Verify each on the user's servers with their real xray before moving on (one at a time).
1. **Hedioum-Pool-Tunnel** — https://github.com/hedioum/Hedioum-Pool-Tunnel — video https://www.youtube.com/watch?v=Sueh8qgzL-0
2. **BackPack** — https://github.com/AminMGMT/BackPack — video https://www.youtube.com/watch?v=W31f__63PM4 — user suggests **wss + mux** as best (verify).
3. **Phormal** — https://github.com/Schmi7zz/Phormal — video https://www.youtube.com/watch?v=BVZmavY7yj0
4. **packet-tunnel** — https://github.com/eris4444/packet-tunnel — video https://www.youtube.com/watch?v=v6tPmUHi2r0
5. **tunnelforge** — https://github.com/SamNet-dev/tunnelforge — user says probably not great; evaluate first, skip if weak.
Also: the user wants strong per-tunnel optimization applied where each tool supports it.
