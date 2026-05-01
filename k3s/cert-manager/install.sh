#!/usr/bin/env bash
# Install cert-manager into the k3s cluster, ready for the Route 53 DNS-01
# ClusterIssuer.  Idempotent.
set -euo pipefail

VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG

echo "[cert-manager] applying upstream manifests (${VERSION})"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${VERSION}/cert-manager.yaml"

echo "[cert-manager] waiting for the controller to be Ready"
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s

echo "[cert-manager] done. Next: create the Route 53 credentials Secret and apply cluster-issuer.yaml"
