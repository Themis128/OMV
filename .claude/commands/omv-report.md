Read and summarise the latest omv inventory + healthcheck from the omv-reports branch.

Usage: /omv-report            ← reads omv (main node)
       /omv-report ha         ← reads omv-ha
       /omv-report both       ← reads both nodes

## Steps

### 1 — Fetch the report file(s)

Call mcp__github__get_file_contents for each requested node:

  omv (main):
    owner: themis128, repo: omv, branch: omv-reports
    path: reports/latest-inventory.txt
    Also fetch: reports/latest-healthcheck.txt

  omv-ha:
    path: reports/latest-inventory-ha.txt
    Also fetch: reports/latest-healthcheck-ha.txt

The content is base64-encoded — decode it before reading.

### 2 — Present a structured summary

For each node print:

**Node**: omv (or omv-ha)
**Collected**: <timestamp from first line of inventory>

#### System
- Model / kernel / uptime / load average / memory usage (from healthcheck)

#### Storage
- Table: device | size | used% | mount | label
  Pull from "Filesystem usage (df)" section.
- 🚨 Flag any filesystem at ≥ 85% used.

#### Disk usage breakdown (if present)
- For each mount point in "Disk usage — top directories" section:
  List top 5 subdirs by size, sorted descending.
- Call out the single largest consumer on each disk.

#### k3s / Kubernetes
- Is k3s service active? (from Services section)
- etcd snapshot sizes and count (from "etcd snapshots" sub-section)
- Container image storage size (from "k3s images" sub-section)

#### Services
- List any failed systemd units (from "Failed units" sub-section).
- Flag if k3s, tailscaled, ssh, or nginx are inactive.

#### NFS exports (if any)

### 3 — Recommendations

After the summary, print a "What needs action" list:
- Any disk ≥ 85%: identify the top consumer and suggest how to free space
  * etcd snapshots > 3 → reduce etcd-snapshot-retention or delete old ones
  * containerd images → run: sudo k3s crictl rmi --prune
  * kubelet pods logs → check /var/log/pods
- Any failed systemd units → suggest restart command
- High load average (> 4 on a 4-core Pi) → note it
