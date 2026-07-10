# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).

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
