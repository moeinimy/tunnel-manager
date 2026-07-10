# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).

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
