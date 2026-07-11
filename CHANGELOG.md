# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).

## [1.9.0] - 2026-07-11

### Changed
- **WaterWall now uses real encryption (`EncryptionClient/Server`,
  chacha20-poly1305) instead of the XOR obfuscator.** The XOR obfuscator dropped
  connections and plain transparent links get DPI-throttled; a proper encrypted
  link (shared password) masks the tunnel and forwards reliably — the WaterWall
  equivalent of GOST's mtls. Encryption is on by default (password prompted).

## [1.8.3] - 2026-07-11

### Changed
- **WaterWall XOR obfuscation is now optional and OFF by default.** The default
  is a transparent TcpListener→TcpConnector tunnel, which carries xray/Reality
  reliably (Reality already camouflages itself; the XOR obfuscator was dropping
  those connections). Enable XOR only for plain, non-camouflaged traffic.

## [1.8.2] - 2026-07-11

### Fixed
- **Critical: `update` rendered per-tunnel units with the temp extraction path.**
  During `install.sh --update`, `TM_BIN_DIR` kept its value from the temporary
  source tree, so every userspace tunnel's `ExecStart` pointed at
  `/tmp/…/bin/<binary>` and failed (status 127) on the next restart/reboot.
  `TM_BIN_DIR` is now unset and recomputed to `/opt/tunnel-manager/bin`. Re-run
  `tunnelctl update` on each server to repair existing units.

## [1.8.1] - 2026-07-11

### Fixed
- **WaterWall service failed to start (status=200/CHDIR).** systemd applied
  `WorkingDirectory` before `ExecStartPre` could create it, so the service never
  started. Removed `WorkingDirectory`; `ExecStart` now `cd`s into the prepared
  directory itself.

## [1.8.0] - 2026-07-11

### Added
- **WaterWall transport driver (7th protocol).** radkesvat/WaterWall — a C++
  network core configured as a node graph. The driver generates a proven simple
  reverse-tunnel profile (TcpListener → XOR Obfuscator → TcpConnector) that masks
  the stream against DPI. Auto binary download (old-cpu build by default for max
  VPS compatibility), core.json + config.json, systemd with WorkingDirectory.

### Notes
- Seven selectable protocols now ship: **GRE, Paqet, Backhaul, Rathole, GOST,
  FRP, WaterWall.** (ReverseTlsTunnel is merged upstream into WaterWall.)

## [1.7.0] - 2026-07-11

### Added
- **FRP transport driver (6th protocol).** fatedier/frp — a mature reverse proxy.
  Installs both frps/frpc, generates TOML config with `transport.tls.enable`,
  and runs the right binary per role (server=frps on Iran exposing ports,
  client=frpc on foreign mapping them to local services). TLS on by default.

## [1.6.1] - 2026-07-11

### Changed
- **GOST default transport is now `mtls`** (multiplexed TLS) instead of `tcp`.
  Plain `relay+tcp` opens a fresh unencrypted connection per request, which
  Iran's DPI throttles/resets and which breaks latency-sensitive handshakes
  (e.g. xray Reality — seen as ~10s stalls with no response). `mtls`/`mwss` keep
  a persistent multiplexed, HTTPS-looking connection like Backhaul/Rathole do.

## [1.6.0] - 2026-07-11

### Added
- **GOST v3 relay driver (5th protocol).** go-gost/gost — a versatile relay with
  tcp/wss/mwss/grpc transports. Iran side listens locally and forwards ports
  through a relay chain to the foreign side (Iran→foreign). Auto binary download;
  the relay command (with credentials) is rendered into a `0700` wrapper script
  so secrets stay out of the world-readable unit file.

## [1.5.0] - 2026-07-11

### Added
- **Rathole transport driver (4th protocol).** rapiz1/rathole — a lightweight,
  fast Rust reverse tunnel. Auto binary download (zip), TOML config, systemd.
  Service names are derived from the public port so both ends match
  deterministically. Adds `unzip` as a dependency.

## [1.4.0] - 2026-07-11

### Added
- **Backhaul transport driver (3rd protocol).** Musixal/Backhaul — a fast
  Iranian reverse tunnel for NAT/firewall traversal with tcp/tcpmux/ws/wsmux
  transports and multiplexing. Selectable per-tunnel like GRE/Paqet: auto binary
  download, TOML config generation, systemd service. Server side owns the public
  ports + forwarding map; client dials out.

## [1.3.1] - 2026-07-11

### Added
- **Persistent Telegram keyboard** under the chat input + `/` command menu
  (no `/start` needed each time).
### Fixed
- Updates now restart `tm-monitor`/`tm-bot` so new code (traffic accounting, bot
  UI) takes effect immediately — fixes usage showing all zeros after an update.

## [1.3.0] - 2026-07-11

### Added
- **Historical traffic usage over time windows.** The monitor now records
  monotonic per-tunnel totals (surviving interface counter resets) and periodic
  history samples, so you can see data used in the **last 1h / 12h / 24h / 7d /
  30d / all-time**. Available as `tunnelctl usage`, in the menu, and via the
  bot's new **📅 Usage** button / `/usage` command. History is bounded (~40 days)
  and removed with the tunnel.

## [1.2.0] - 2026-07-11

### Added
- **Zero-config multi-server control.** Every server now runs a tiny peer agent
  (systemd socket + handler) that answers a small allowlist of commands
  (`list/status/bandwidth/report/logs/restart`) — but ONLY for requests arriving
  over a tunnel interface from the connected peer's inner IP. No SSH keys, no
  manual `peer add`: as soon as a tunnel is up, the foreign bot/CLI can see and
  control the Iran side automatically. Peers are auto-discovered from tunnels.
  Firewalled to tunnel interfaces (`tm+`) and re-checked per request.

### Changed
- Peer management is now automatic; the old SSH-key-based `peer add` flow is
  removed in favour of the agent. `tunnelctl peer list` / `peer run <tunnel>
  <cmd>` and the bot's 🌐 Peers button use it.

## [1.1.0] - 2026-07-11

### Added
- **Interactive Telegram bot with inline (glass) buttons.** `/menu` opens a
  button panel: Status, System, Bandwidth, Tunnels, Restart (per-tunnel picker),
  Report, Peers, Reboot (with confirm). Buttons and typed commands share one
  handler.
- **Multi-server control (peers).** Register another server (e.g. the Iran box,
  reachable over the tunnel's inner IP) with `tunnelctl peer add`; the foreign
  bot/CLI can then view it — solving the "Iran can't reach Telegram" problem.
  Uses a dedicated SSH key over the private tunnel link.
- **`tunnelctl bandwidth`** — per-tunnel traffic table (current rate, totals),
  also available in the menu and via the bot.
- Telegram `/bandwidth`, `/traffic`, `/peers`, `/menu` commands.

### Improved
- **Network optimization is much more thorough**: ~40 tuned sysctl keys (TCP
  keepalive/timeouts, window scaling, SACK, conntrack table size, local port
  range, swappiness, IPv6 forwarding, netdev budget…) plus reversible NIC tuning
  (tx queue length and NIC ring buffers). All still fully reverted by
  `optimize revert`.

## [1.0.7] - 2026-07-11

### Added
- **Full-relay forwarding mode for GRE.** When adding/editing an Iran-side GRE
  tunnel you can now pick: relay **ALL** ports to the peer (except a protected
  set like SSH), specific ports only, or none. The relay rules (ip_forward,
  DNAT, SNAT, FORWARD) are applied automatically and persist across reboots via
  the tunnel's systemd unit — no more manual iptables.

### Changed
- **Installer now auto-applies network optimization** (reversible) and enables
  IP forwarding, so forwarding tunnels work out of the box. Post-install steps
  reduced to just "Add tunnel". Pass `--no-optimize` to skip.

## [1.0.6] - 2026-07-11

### Fixed
- **Reachability probe no longer reports false 100% loss for GRE.** Many Iran
  transit paths drop ICMP *inside* GRE while carrying TCP normally, so `ping`
  wrongly showed a healthy tunnel as down. The monitor now falls back to a TCP
  round-trip probe (a RST from a closed port still proves connectivity) and
  `status` shows which probe was used (`icmp`/`tcp`).

## [1.0.5] - 2026-07-11

### Changed
- **GRE tunnels are now created with the classic `ip tunnel add ... mode gre`**
  form instead of `ip link add ... type gre`. Both proven Iran tunnel tools
  (vatanhost, Azumi 6TO4-GRE-IPIP-SIT) use the classic form; the newer form
  produced tunnels whose return traffic was dropped on some Iran transit paths.
  Teardown now uses `ip tunnel del` accordingly.

## [1.0.4] - 2026-07-11

### Fixed
- **Paqet client firewall rules were one-directional (server-only).** NOTRACK
  and RST-drop are now applied for both directions of the tunnel port, so the
  client (Iran) side no longer has its raw packets mangled by conntrack/RST.
- **Paqet binary validated by ELF magic** and self-healed if a previous run
  installed a non-binary (fixes `Exec format error` / `status=203/EXEC`).
- **Paqet config now matches the upstream schema exactly**: added `log.level`
  and `network.tcp.local_flag`/`remote_flag`, matching hanselime/paqet examples.

### Changed
- **GRE now defaults to keyless.** Iran's border commonly drops keyed GRE while
  passing plain GREv0; keys are only needed for multiple tunnels between the
  same IP pair.
- GRE health is based on interface UP state, not peer ping, to stop the monitor
  from restart-flapping when the remote peer is temporarily unreachable.

## [1.0.1] - 2026-07-11

### Fixed
- `unbound variable: $1` error when invoking tunnel actions (remove, edit,
  start/stop/restart, enable/disable, status, logs) and restore from the
  interactive menu (functions are called with no argument under `set -u`).
  This also blocked removing tunnels from the menu.

## [1.0.0] - 2026-07-10

### Added
- Unified tunnel manager supporting **GRE** (kernel) and **Paqet** (userspace
  raw-socket KCP) as first-class, per-tunnel selectable protocols.
- Pluggable transport-driver architecture (`drivers/driver.sh` dispatcher).
- Unlimited independent tunnel profiles; automatic `/30` IPAM allocation with
  conflict/duplicate detection; hub, spoke and mesh topologies.
- Persistent per-tunnel `systemd` units (survive reboot) with enable/disable
  auto-start.
- Interactive colorful CLI menu plus a fully scriptable command interface.
- Reversible network optimization (BBR/fq, buffers, forwarding, queues) with a
  saved backup of original sysctl values.
- Health monitor daemon with latency/loss/bandwidth sampling and bounded
  auto-recovery (retry with alerting).
- Optional Telegram integration: notifications + command bot
  (`/status /tunnels /system /bandwidth /report /logs /restart /reboot`).
- Daily/weekly/monthly reports (systemd timer) delivered to Telegram.
- Backup & restore of all configuration, portable across servers.
- One-command installer, self-update from GitHub, and clean uninstall that
  reverts optimization.
- Structured logging with logrotate.
