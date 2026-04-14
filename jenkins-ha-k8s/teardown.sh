#!/usr/bin/env bash
# teardown.sh — Remove all Jenkins HA resources.
# Usage: ./teardown.sh [--delete-pvc]
#
# By default, the PVC is kept to protect Jenkins data.
# Pass --delete-pvc to remove everything including storage.

set -euo pipefail

NS="jenkins"
DELETE_PVC=false

if [ "${1:-}" = "--delete-pvc" ]; then
  DELETE_PVC=true
fi

echo "============================================="
echo "  Jenkins HA — Teardown"
echo "============================================="
echo ""

echo "» Deleting StatefulSet..."
kubectl -n "$NS" delete statefulset jenkins --ignore-not-found=true

echo "» Deleting Services..."
kubectl -n "$NS" delete service jenkins jenkins-headless --ignore-not-found=true

echo "» Deleting ConfigMap..."
kubectl -n "$NS" delete configmap jenkins-ha-scripts --ignore-not-found=true

echo "» Deleting Lease..."
kubectl -n "$NS" delete lease jenkins-leader --ignore-not-found=true

echo "» Deleting RBAC..."
kubectl -n "$NS" delete rolebinding jenkins-ha-rolebinding --ignore-not-found=true
kubectl -n "$NS" delete role jenkins-ha-role --ignore-not-found=true

echo "» Deleting ServiceAccount..."
kubectl -n "$NS" delete serviceaccount jenkins-ha-sa --ignore-not-found=true

if [ "$DELETE_PVC" = true ]; then
  echo ""
  echo "» Deleting PVC (ALL JENKINS DATA WILL BE LOST)..."
  kubectl -n "$NS" delete pvc jenkins-ha-home --ignore-not-found=true
  echo "» Deleting Namespace..."
  kubectl delete namespace "$NS" --ignore-not-found=true
  echo ""
  echo "✓ Complete teardown finished (including PVC and namespace)."
else
  echo ""
  echo "✓ Teardown complete. PVC 'jenkins-ha-home' was KEPT."
  echo "  To delete it too: ./teardown.sh --delete-pvc"
fi
