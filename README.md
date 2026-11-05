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
```
curl -fsSL https://raw.githubusercontent.com/ska196/sing-box/main/sb.sh -o sb.sh && sh sb.sh
```

### IPv4 + IPv6 or IPv6-only host (recommended)
```
curl -fsSL https://raw.githubusercontent.com/ska196/sing-box/main/sb6.sh -o sb6.sh && sh sb6.sh
```

This setup is recommended because it is less likely to be blocked.

## Usage

```sh
sh sb.sh --show           # Show addresses, client links, and credentials
sh sb.sh --client-config  # Write client configs (an install also does this)
sh sb.sh --uninstall      # Stop and remove the installation
```

## Client configs

Files are written to `/root/sing-box` and contain credentials, so copy them over a secure channel. Re-running the installer changes the credentials, so copy them again afterwards.

| File | Use with | Differences |
| --- | --- | --- |
| `clash-pc.yaml` | Clash Verge Rev, Clash Party (Windows, macOS, Linux) | Local proxy on port 7890, strict routing, LAN bypasses the TUN |
| `clash-mobile.yaml` | mihomo-based apps (Android, iOS) | No local proxy port or process lookup |
| `singbox-pc.json` | sing-box 1.14+ (Windows, macOS, Linux) | Strict routing, LAN bypasses the TUN |
| `singbox-android.json` | sing-box 1.14+ (Android) | LAN bypasses the TUN |
| `singbox-ios.json` | sing-box 1.14+ (iOS) | None |
| `egern.yaml` | Egern (Apple devices) | None |

All of them send China IPs and LAN traffic direct and everything else through a `PROXY` group, with `223.5.5.5` as DNS.

- Deciding whether an address is in China means looking up every domain, so `223.5.5.5` sees all the domains you visit, including proxied ones. Proxied traffic is still resolved on the server, so a poisoned answer does not break it.
- Clash and Egern have no Snell v6 client, so only the sing-box files include that node.
- In Clash Party, leave DNS override off so the profile's DNS is used.

Normal installation applies the memory, network and logging settings automatically; no separate tuning step is needed.
