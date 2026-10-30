# sing-box

Install the latest stable sing-box on Debian, Ubuntu, or Alpine. Supports systemd, OpenRC, and background mode for containers without an init system.

| Protocol | Port |
| --- | --- |
| VLESS + REALITY + XTLS Vision | 60001/tcp |
| Hysteria2 | 60002/udp |
| TUIC v5 | 60003/udp |
| Snell v5 (v4-compatible clients) | 60004/tcp |
| Snell v6 | 60005/tcp |

REALITY, Hysteria2, and TUIC all use `www.tencentcloud.com` as the SNI. Hysteria2 and TUIC use a self-signed certificate, so clients skip certificate verification.

## Install

### IPv4-only host

curl -fsSL https://raw.githubusercontent.com/ska196/sing-box/main/sb.sh -o sb.sh && sh sb.sh

### IPv4 + IPv6 or IPv6-only host (recommended)

curl -fsSL https://raw.githubusercontent.com/ska196/sing-box/main/sb6.sh -o sb6.sh && sh sb6.sh

This setup is recommended because it is less likely to be blocked.

## Usage

```sh
sh sb.sh --show       # Show addresses, client links, and credentials
sh sb.sh --uninstall  # Stop and remove the installation
```
