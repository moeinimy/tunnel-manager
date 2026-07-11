# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).

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
