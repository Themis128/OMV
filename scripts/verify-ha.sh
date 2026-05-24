#!/usr/bin/env bash
# Verify the cluster is in 2-control-plane HA mode and all workloads are healthy.
# Used as the post-step of promote-omv-ha.sh and as a standalone health check.
#
# Exits non-zero if any check fails.
set -euo pipefail

EXPECTED_CONTROL_PLANES="${EXPECTED_CONTROL_PLANES:-2}"

ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

fail=0

# 1) Both nodes Ready and labeled control-plane.
echo "== nodes =="
kubectl get nodes -o wide
cp_count="$(kubectl get nodes \
  -l 'node-role.kubernetes.io/control-plane=true' \
  --no-headers 2>/dev/null | wc -l)"
if [[ "${cp_count}" -ne "${EXPECTED_CONTROL_PLANES}" ]]; then
  bad "expected ${EXPECTED_CONTROL_PLANES} control-plane nodes, found ${cp_count}"
  fail=1
else
  ok "${cp_count} control-plane nodes present"
fi

not_ready="$(kubectl get nodes --no-headers \
  | awk '$2 != "Ready" {print $1}')"
if [[ -n "${not_ready}" ]]; then
  bad "nodes not Ready: ${not_ready}"
  fail=1
else
  ok "all nodes Ready"
fi

# 2) etcd member list (works on either control-plane node via k3s).
echo "== etcd members =="
if command -v k3s >/dev/null 2>&1; then
  if sudo k3s etcd-snapshot ls >/dev/null 2>&1; then
    ok "k3s etcd reachable"
  else
    bad "k3s etcd-snapshot ls failed — etcd may be unhealthy"
    fail=1
  fi
else
  echo "  (k3s binary not on this host — skip etcd check; run on a control-plane node to see member list)"
fi

# 3) All pods Running or Completed.
echo "== pods =="
bad_pods="$(kubectl get pods -A --no-headers \
  | awk '$4 != "Running" && $4 != "Completed" {print $1"/"$2" -> "$4}')"
if [[ -n "${bad_pods}" ]]; then
  bad "pods not Running/Completed:"
  printf '%s\n' "${bad_pods}" >&2
  fail=1
else
  ok "all pods Running or Completed"
fi

# 4) cloudless-app has its expected replicas.
echo "== cloudless-app =="
if kubectl -n cloudless get deploy cloudless-app >/dev/null 2>&1; then
  desired="$(kubectl -n cloudless get deploy cloudless-app -o jsonpath='{.spec.replicas}')"
  ready="$(kubectl -n cloudless get deploy cloudless-app -o jsonpath='{.status.readyReplicas}')"
  if [[ "${desired}" == "${ready}" && -n "${ready}" ]]; then
    ok "cloudless-app: ${ready}/${desired} ready"
  else
    bad "cloudless-app: ${ready:-0}/${desired} ready"
    fail=1
  fi
else
  echo "  (cloudless-app deployment not present — skip)"
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi

ok "HA cluster looks healthy"
