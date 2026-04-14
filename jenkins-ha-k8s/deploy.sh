#!/usr/bin/env bash
# deploy.sh — Deploy Jenkins HA to your Kubernetes cluster.
# Usage: ./deploy.sh [STORAGE_CLASS]
#
# Prerequisites:
#   - kubectl configured against your cluster
#   - A StorageClass that supports ReadWriteMany (RWX)
#
# For local dev with kind/minikube, see README.md for NFS setup instructions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"
STORAGE_CLASS="${1:-}"

echo "============================================="
echo "  Jenkins HA on Kubernetes — Deployment"
echo "============================================="
echo ""

# ── Pre-flight checks ────────────────────────────────────────────────────────
echo "» Pre-flight checks..."

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found. Install it first."
  exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot reach the Kubernetes cluster. Check your kubeconfig."
  exit 1
fi

echo "  ✓ kubectl connected to cluster"

# ── Patch StorageClass if provided ────────────────────────────────────────────
if [ -n "$STORAGE_CLASS" ]; then
  echo "» Setting StorageClass to: $STORAGE_CLASS"
  # Uncomment and set the storageClassName in the PVC
  sed -i "s|# storageClassName:.*|storageClassName: $STORAGE_CLASS|" \
    "$MANIFESTS_DIR/04-pvc.yaml"
  echo "  ✓ PVC updated"
fi

# ── Apply manifests ──────────────────────────────────────────────────────────
echo ""
echo "» Applying manifests..."

for f in "$MANIFESTS_DIR"/*.yaml; do
  echo "  Applying $(basename "$f")..."
  kubectl apply -f "$f"
done

echo ""
echo "» Waiting for pods to start..."
echo "  (This may take 1-2 minutes for image pulls)"
echo ""

# Wait for the StatefulSet to create both pods
sleep 5

# ── Watch rollout ────────────────────────────────────────────────────────────
echo "» Watching pod status (press Ctrl+C to stop watching)..."
echo ""

# Show status every 5 seconds for up to 2 minutes
for i in $(seq 1 24); do
  echo "--- $(date -u '+%H:%M:%S') ---"
  kubectl -n jenkins get pods -l app=jenkins -L jenkins-role -o wide 2>/dev/null || true
  echo ""
  kubectl -n jenkins get lease jenkins-leader \
    -o jsonpath='Lease holder: {.spec.holderIdentity}  |  Renew time: {.spec.renewTime}' 2>/dev/null || true
  echo ""
  echo ""

  # Check if one pod is active
  active_pod=$(kubectl -n jenkins get pods -l app=jenkins,jenkins-role=active \
    -o name 2>/dev/null || true)
  if [ -n "$active_pod" ]; then
    echo "✓ Active pod detected: $active_pod"
    echo ""
    break
  fi

  sleep 5
done

# ── Final status ─────────────────────────────────────────────────────────────
echo "============================================="
echo "  Deployment Summary"
echo "============================================="
echo ""
kubectl -n jenkins get pods -l app=jenkins -L jenkins-role -o wide
echo ""
kubectl -n jenkins get lease jenkins-leader -o yaml 2>/dev/null | grep -E 'holderIdentity|renewTime' || true
echo ""
kubectl -n jenkins get endpoints jenkins
echo ""
echo "============================================="
echo "  To access Jenkins:"
echo "    kubectl -n jenkins port-forward svc/jenkins 8080:8080"
echo "    Then open: http://localhost:8080"
echo ""
echo "  To test failover:"
echo "    ./demo-failover.sh"
echo "============================================="
