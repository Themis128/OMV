# Port map — Pi 5 / OMV node

Single host, multiple processes. Document any change here in the same PR.

| Host port | Owner | Notes |
|-----------|-------|-------|
| 53 (TCP+UDP) | pihole-FTL | LAN DNS |
| 80 | OMV nginx (admin UI redirect) | do not bind |
| 443 | pihole-FTL (Pi-hole admin) | do not bind |
| 8080 | OMV nginx (admin UI HTTP) | do not bind |
| **18080** | **k3s Traefik (HTTP entrypoint)** | router forwards external 80 → 18080 |
| **18443** | **k3s Traefik (HTTPS entrypoint)** | router forwards external 443 → 18443 |
| 6443 | k3s API server | LAN-only |
| 9090 | uptime-kuma | LAN/tailnet only |
| 9091 | portainer | LAN/tailnet only |
| 3000 | (reserved — homepage) | LAN/tailnet only |

## Router port forwarding (home gateway)

| External | Internal | Internal port |
|----------|----------|---------------|
| 80/tcp   | 192.168.1.128 | 18080 |
| 443/tcp  | 192.168.1.128 | 18443 |

This way external `https://cloudless.online` reaches Traefik without conflicting with anything on the Pi.

For local LAN testing while still inside the router NAT, use `https://cloudless.online:18443` or add an `/etc/hosts` override pointing the hostname to `192.168.1.128`.
