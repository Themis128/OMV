# Runbook — failover & recovery

For control-plane (k3s API) failover between `omv` and `omv-ha`, see
[ha-control-plane-promotion.md](ha-control-plane-promotion.md). This file
covers user-traffic failover (Route 53) and routine recovery.

## Verify standby is healthy

```bash
# from anywhere
curl -fsS https://cloudless.online/api/health

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

## Re-issue TLS cert (forced)

```bash
kubectl -n cloudless delete secret cloudless-online-tls
# cert-manager re-issues automatically; watch:
kubectl -n cloudless describe certificate cloudless-online-tls
kubectl -n cert-manager logs deploy/cert-manager --tail=80
```
