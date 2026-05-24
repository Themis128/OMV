# Runbook — failover & recovery

For control-plane (k3s API) failover between `omv` and `omv-ha`, see
[ha-control-plane-promotion.md](ha-control-plane-promotion.md). This file
covers user-traffic failover (Route 53) and routine recovery.

## Verify standby is healthy

```bash
# from anywhere
curl -fsS https://cloudless.gr/api/health

# from the Pi
kubectl -n cloudless get pods -l app.kubernetes.io/name=cloudless-app
kubectl -n cloudless logs deploy/cloudless-app --tail=50
```

## Force a failover (test)

Run from any machine with the `cloudless` AWS profile:
```bash
# disable the primary health check temporarily by tweaking its endpoint to a 404
# (or pause the CloudFront distribution).  Wait ~3 health-check intervals.
# Verify DNS flipped:
dig +short cloudless.gr
# Should now resolve to the Pi's WAN IP.
```

Reverse the change afterwards.

## Recover from primary outage

1. Confirm Route 53 has flipped (`dig` shows Pi WAN IP).
2. Verify Pi load:  `kubectl top pods -n cloudless` (ensure not OOM/CPU-saturated).
3. Tail logs:  `kubectl -n cloudless logs deploy/cloudless-app -f`.
4. When primary recovers, Route 53 health-check will flip DNS back automatically (typically within one TTL).

## Node failover on the LAN (`omv` down, `omv-ha` survives)

keepalived holds a VIP at `192.168.1.200` shared by both Pis. When `omv` goes
down, the VIP moves to `omv-ha` within seconds (BACKUP → MASTER) and user
traffic to `cloudless.gr` / `manage.cloudless.gr` keeps serving.

The kubectl API goes read-only during the outage — that is expected with
2-member etcd (quorum is lost when one node is down). Verify and operate from
the survivor:

```bash
# point kubectl at omv-ha or the VIP, not the dead primary
kubectl --server=https://192.168.1.200:6443 get nodes
kubectl --server=https://192.168.1.130:6443 get nodes
```

When `omv` returns, the VIP migrates back to it automatically. See the
"Failure tolerance" caveat in
[ha-control-plane-promotion.md](ha-control-plane-promotion.md) for what this
buys you and what it doesn't.

## Standby returns 5xx / Cloudflare 530 (`cloudless.gr` down)

`cloudless.gr` is fronted by Cloudflare. A `502` means Cloudflare reached
the Pi origin but it answered badly; a `530` means the tunnel has **no origin
connection at all** — both mean "something on the Pi is down". If
`manage.cloudless.gr` is also affected, it's the whole Pi ingress, not
just `cloudless-app`.

`scripts/recover-standby.sh` walks the stack outside-in (SSH reachability →
host services `k3s`/`cloudflared`/`tailscaled` → k3s node → `cloudless-app`)
and applies the cheapest fix at each layer:

```bash
./scripts/recover-standby.sh          # diagnose only, change nothing
./scripts/recover-standby.sh --yes    # diagnose AND restart / roll back

# defaults: OMV_HOST=tbaltzakis@omv  STANDBY_URL=https://cloudless.gr/api/health
```

**No SSH / no laptop?** The `recover-standby` GitHub Actions workflow runs that
same script via Tailscale from a GitHub-hosted runner — trigger it from
[Actions → recover-standby](https://github.com/Themis128/OMV/actions/workflows/recover-standby.yml)
in any browser, phone included. Requires `TS_AUTHKEY` and `OMV_SSH_KEY`
secrets in the repo.

If the script can't even SSH to `omv` (and `omv` is unreachable by Tailscale
and LAN too), the Pi itself is down — **power-cycle it**; `k3s` and
`cloudflared` are enabled systemd units and rejoin on boot. The script's
final `--yes` step rolls `cloudless-app`, and rolls it **back** to the
previous ReplicaSet if a fresh rollout doesn't converge — the recovery path
when a bad image was deployed.

The primary (`cloudless.gr`, CloudFront + Lambda) is independent of the Pi
and unaffected by a standby outage; only HA redundancy is lost.

## etcd quorum lost (`omv` loops "pre-candidate", writes blocked)

**Symptom:** `journalctl -u k3s | grep -i "pre-candidate\|handshake failed"` shows
omv's etcd repeatedly trying to elect itself but failing — the 2-member cluster
lost quorum because omv-ha is unreachable.

**Recovery** (run on `omv` as root, or via the workflow with `etcd_recover = true`):

```bash
sudo ~/OMV/scripts/etcd-recover.sh
# Prompts before each destructive step.
# Set REJOIN=1 to also re-join omv-ha automatically after reset.
```

What it does:
1. Stops k3s on omv-ha (SSH best-effort)
2. Stops k3s on omv
3. Snapshots `server/db` to `/var/lib/rancher/k3s-reset-backup-<ts>`
4. Runs `k3s server --cluster-reset` (rewrites etcd to single-member)
5. Restarts k3s; waits for node Ready
6. Optionally re-joins omv-ha as a control-plane server

**From the GitHub UI (no SSH needed):**
[Actions → recover-standby](https://github.com/Themis128/OMV/actions/workflows/recover-standby.yml)
→ Run workflow → check **"etcd cluster-reset"** → Run workflow.

## etcd snapshot restore (catastrophic primary loss)

Snapshots are written every 6 h to S3 bucket `cloudless-etcd-snapshots` by
IAM principal `omv-main-cli`. If `omv` is unrecoverable and you need to
rebuild etcd state on `omv-ha`:

```bash
# 1) pull the latest snapshot
aws s3 ls s3://cloudless-etcd-snapshots/ --profile cloudless | tail -5
aws s3 cp s3://cloudless-etcd-snapshots/<snapshot>.zip /tmp/ --profile cloudless

# 2) on omv-ha, reset etcd from the snapshot (this rewrites cluster state —
#    do NOT run unless omv is truly gone for good)
sudo systemctl stop k3s
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/tmp/<snapshot>.zip
sudo systemctl start k3s

# 3) verify
kubectl get nodes
kubectl get pods -A
```

After a `--cluster-reset` you'll need to re-join any other servers as fresh
members; treat it as a clean cluster.

## Rotate the omv-main-cli AWS key (etcd S3 snapshots)

The `omv-main-cli` IAM key is stored in `/etc/rancher/k3s/config.yaml` and
used by k3s for etcd S3 snapshots.

1. In AWS IAM: create a new access key for `omv-main-cli`, save both values.
2. On `omv`:
   ```bash
   sudo ETCD_S3_ACCESS_KEY=<new-id> ETCD_S3_SECRET_KEY=<new-secret> \
     ~/OMV/scripts/configure-k3s.sh
   sudo systemctl restart k3s
   ```
3. Verify next snapshot lands in S3:
   ```bash
   aws s3 ls s3://cloudless-etcd-snapshots/etcd/ --profile cloudless | tail -3
   ```
4. Deactivate then delete the old key in IAM.

## Rotate ECR pull credentials manually

```bash
kubectl -n cloudless create job --from=cronjob/ecr-cred-refresher ecr-refresh-manual-$(date +%s)
```

## Rotate the cloudless-pi-standby IAM access key

1. `aws iam create-access-key --user-name cloudless-pi-standby --profile cloudless`
2. Update SSM:
   ```
   aws ssm put-parameter --name /cloudless/production/pi-standby/aws-access-key-id --type String --overwrite --value <NEW>
   aws ssm put-parameter --name /cloudless/production/pi-standby/aws-secret-access-key --type SecureString --overwrite --value <NEW>
   ```
3. Update `/etc/cloudless/pi-standby.env` on the Pi (root:root 600).
4. Recreate the in-cluster Secret:
   ```
   kubectl -n cloudless delete secret pi-standby-aws-creds
   kubectl -n cloudless create secret generic pi-standby-aws-creds --from-env-file=/etc/cloudless/pi-standby.env
   ```
5. Trigger an immediate refresh: `kubectl -n cloudless create job --from=cronjob/ecr-cred-refresher post-rotate-$(date +%s)`
6. Deactivate then delete the old key after 24h:
   ```
   aws iam update-access-key --user-name cloudless-pi-standby --access-key-id <OLD> --status Inactive --profile cloudless
   # 24h later:
   aws iam delete-access-key --user-name cloudless-pi-standby --access-key-id <OLD> --profile cloudless
   ```

## TLS

Public TLS for `cloudless.gr` is handled by Cloudflare Universal SSL on the
edge — nothing to do on the cluster side. The Cloudflare Tunnel uses
`noTLSVerify: true` to the origin, so Traefik's default self-signed cert is
fine and cert-manager is not required.

If a future deployment needs a real origin cert (e.g. exposing Traefik
directly on the LAN with TLS), put back the cert-manager annotation and TLS
section on the Ingress and apply `k3s/cert-manager/cluster-issuer.yaml`
together with a populated `cloudflare-api-token` Secret.
