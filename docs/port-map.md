# Port map — Pi 5 / OMV node

Single host, multiple processes. Document any change here in the same PR.

| Host port | Owner | Notes |
|-----------|-------|-------|
| 53 (TCP+UDP) | pihole-FTL | LAN DNS |
| 80 | OMV nginx (admin UI redirect) | do not bind |
| 443 | pihole-FTL (Pi-hole admin) | do not bind |
| 8080 | OMV nginx (admin UI HTTP) | do not bind |
| **18080** | **k3s Traefik (HTTP entrypoint)** | reached by cloudflared (loopback), not the WAN |
| **18443** | **k3s Traefik (HTTPS entrypoint)** | reached by cloudflared (loopback), not the WAN |
| 6443 | k3s API server | LAN-only |
| 8123 | Home Assistant (`home-assistant` ns, `hostNetwork: true` on omv) | LAN/tailnet only |
| 3001 | uptime-kuma | LAN/tailnet only |
| 9091 | portainer | LAN/tailnet only |
| 3000 | (reserved — homepage) | LAN/tailnet only |

## External ingress

`cloudless.gr` reaches the Pi via **Cloudflare Tunnel** (outbound-only
`cloudflared` daemon on omv). There is **no router port-forward**, no
WAN-IP exposure, and no DDNS. See
[ha-architecture.md](ha-architecture.md) and `scripts/configure-cloudflared.sh`.

For local LAN testing, add a hosts override `192.168.1.128 cloudless.gr`
and use `https://cloudless.gr:18443` (TLS verify off — cert is for the
public hostname through the tunnel).
