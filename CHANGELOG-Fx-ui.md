# Fx-ui Changelog

## Overview
This branch replaces x-ui built-in iptables-based ip limit behavior with nftables-driven port rules synchronized from x-ui DB.

## Included Changes

1. install.sh
- Install runtime dependencies: `nftables`, `sqlite/sqlite3`, `python3`.
- Add firewall readiness check (`ensure_firewall_ready`) to auto-install/enable nftables when missing.
- Add automatic deployment for:
  - `xui-portlimit-sync.sh`
  - `xui-portlimit-sync.service`
  - `xui-portlimit-sync.timer`
- Enable timer at install time and trigger initial sync.

2. x-ui.sh
- Add `sync_portlimit_rules()` helper.
- Trigger sync service after successful `start` and `restart`.
- Keep menu/UI behavior unchanged.

3. xui-portlimit-sync.sh
- Read limit from `inbounds.ip_limit` first, with fallback compatibility to `settings.clients[].limitIp`.
- Build nftables table `inet xui_auto_portlimit` from enabled inbounds.
- Enforce mode:
  - per-port source IP tracking by configured limit
  - on overflow: block the entire port for all source IPs for timeout window
  - auto recovery by timeout
- Add concurrency lock (`flock`) to prevent race conditions when timer/manual runs overlap.

4. systemd units
- `xui-portlimit-sync.service`: oneshot sync job.
- `xui-portlimit-sync.timer`: periodic reconciliation.

## Verified Scenarios
- Add inbound -> rule appears.
- Delete inbound -> rule removed.
- Modify inbound port -> old rule removed, new rule applied.
- Parallel sync triggers -> stable after lock fix.
- Multi-protocol coverage tested: `vmess`, `vless`, `trojan`, `shadowsocks`, `socks`, `http`.

## Notes
- Current upstream x-ui binary may still invoke internal iptables logic. This branch focuses on stable nftables enforcement path and automation around it.
