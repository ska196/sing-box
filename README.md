# sing-box

Install the latest stable sing-box on Debian, Ubuntu, or Alpine. Supports systemd, OpenRC, and background mode for containers without an init system.

| Protocol | TCP port |
| --- | --- |
| VLESS + REALITY + XTLS Vision | 60001 |
| Snell v5 (v4-compatible clients) | 60002 |
| Snell v6 | 60003 |

## Install

Run as root

```sh
curl -fsSL https://raw.githubusercontent.com/ska196/sing-box/main/sb.sh -o sb.sh && sh sb.sh
```

## Usage

```sh
sh sb.sh --show       # Show addresses, client links, and credentials
sh sb.sh --uninstall  # Stop and remove the installation
```
