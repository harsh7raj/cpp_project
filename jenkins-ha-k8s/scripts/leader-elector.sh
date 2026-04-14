#!/usr/bin/env bash
# leader-elector.sh — Lease-based leader election for Jenkins HA.
# Runs inside the sidecar container in an infinite loop.
# Contract: writes "active" or "standby" to ROLE_FILE; labels own pod accordingly.
#
# Identity uses POD_NAME/POD_UID so a restarted pod with the same name but a
# new UID will never mistake an old lease for its own. This allows natural
# lease-expiry failover without any manual intervention.

set -euo pipefail

# ── Configuration (passed via env vars) ──────────────────────────────────────
POD_NAME="${POD_NAME:?POD_NAME must be set}"
POD_UID="${POD_UID:?POD_UID must be set}"
POD_NAMESPACE="${POD_NAMESPACE:?POD_NAMESPACE must be set}"
LEASE_NAME="${LEASE_NAME:-jenkins-leader}"
LEASE_DURATION="${LEASE_DURATION:-15}"
RENEW_INTERVAL="${RENEW_INTERVAL:-5}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"
ROLE_FILE="${ROLE_FILE:-/var/run/jenkins-ha/role}"
MAX_API_FAILURES="${MAX_API_FAILURES:-3}"

# Unique identity for this specific pod instance — survives name reuse
IDENTITY="${POD_NAME}/${POD_UID}"

# ── State ────────────────────────────────────────────────────────────────────
consecutive_failures=0
current_role="standby"

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { echo "[elector] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

write_role() {
  local role="$1"
  echo "$role" > "$ROLE_FILE"
  if [ "$current_role" != "$role" ]; then
    log "Role transition: $current_role -> $role"
    current_role="$role"
  fi
}

label_pod() {
  local role="$1"
  kubectl label pod "$POD_NAME" -n "$POD_NAMESPACE" \
    jenkins-role="$role" --overwrite 2>/dev/null || true
}

epoch_seconds() { date +%s; }

parse_time() {
  local ts="$1"
  date -d "$ts" +%s 2>/dev/null || echo 0
}

# ── Lease helpers ────────────────────────────────────────────────────────────
get_lease() {
  kubectl get lease "$LEASE_NAME" -n "$POD_NAMESPACE" \
    -o jsonpath='{.spec.holderIdentity}|{.spec.renewTime}|{.spec.acquireTime}' 2>/dev/null
}

create_lease_if_missing() {
  if ! kubectl get lease "$LEASE_NAME" -n "$POD_NAMESPACE" &>/dev/null; then
    log "Lease $LEASE_NAME does not exist, creating it..."
    kubectl apply -f - <<EOF
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: ${LEASE_NAME}
  namespace: ${POD_NAMESPACE}
spec:
  leaseDurationSeconds: ${LEASE_DURATION}
EOF
    log "Lease created."
  fi
}

try_acquire() {
  local now_iso
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%S.000000Z')"
  kubectl patch lease "$LEASE_NAME" -n "$POD_NAMESPACE" --type=merge \
    -p "{\"spec\":{\"holderIdentity\":\"${IDENTITY}\",\"leaseDurationSeconds\":${LEASE_DURATION},\"acquireTime\":\"${now_iso}\",\"renewTime\":\"${now_iso}\"}}" \
    2>/dev/null
}

renew_lease() {
  local now_iso
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%S.000000Z')"
  kubectl patch lease "$LEASE_NAME" -n "$POD_NAMESPACE" --type=merge \
    -p "{\"spec\":{\"renewTime\":\"${now_iso}\"}}" \
    2>/dev/null
}

verify_holder() {
  local holder
  holder="$(kubectl get lease "$LEASE_NAME" -n "$POD_NAMESPACE" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)"
  [ "$holder" = "$IDENTITY" ]
}

clear_lease() {
  log "Clearing lease holder (graceful shutdown)..."
  kubectl patch lease "$LEASE_NAME" -n "$POD_NAMESPACE" --type=merge \
    -p '{"spec":{"holderIdentity":null}}' 2>/dev/null || true
}

# ── Role transitions ──────────────────────────────────────────────────────────
become_standby() {
  write_role "standby"
  label_pod "standby"
}

become_active() {
  write_role "active"
  label_pod "active"
  log "I am the leader. identity=$IDENTITY"
}

self_fence() {
  log "FENCING: cannot reach API ($consecutive_failures consecutive failures). Assuming lost leadership."
  become_standby
}

# ── Graceful exit ────────────────────────────────────────────────────────────
cleanup() {
  log "Caught termination signal."
  if [ "$current_role" = "active" ]; then
    clear_lease
  fi
  become_standby
  exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# ── Main loop ────────────────────────────────────────────────────────────────
log "Starting leader elector: pod=$POD_NAME uid=$POD_UID identity=$IDENTITY"
log "Settings: duration=${LEASE_DURATION}s, renew=${RENEW_INTERVAL}s, retry=${RETRY_INTERVAL}s"

mkdir -p "$(dirname "$ROLE_FILE")"
write_role "standby"
label_pod "standby"
create_lease_if_missing

while true; do
  # ── Step 1: Read the lease ────────────────────────────────────────────────
  lease_data="$(get_lease)" || {
    consecutive_failures=$((consecutive_failures + 1))
    log "API call failed ($consecutive_failures/$MAX_API_FAILURES)"
    if [ "$consecutive_failures" -ge "$MAX_API_FAILURES" ]; then
      self_fence
    fi
    sleep "$RETRY_INTERVAL"
    continue
  }

  consecutive_failures=0
  IFS='|' read -r holder renew_time acquire_time <<< "$lease_data"

  # ── Step 2: Am I the current holder (same pod instance)? ─────────────────
  if [ "$holder" = "$IDENTITY" ]; then
    if renew_lease; then
      if [ "$current_role" != "active" ]; then
        become_active
      fi
      sleep "$RENEW_INTERVAL"
      continue
    else
      consecutive_failures=$((consecutive_failures + 1))
      log "Renew failed ($consecutive_failures/$MAX_API_FAILURES)"
      if [ "$consecutive_failures" -ge "$MAX_API_FAILURES" ]; then
        self_fence
      fi
      sleep "$RETRY_INTERVAL"
      continue
    fi
  fi

  # ── Step 3: Is the lease free or expired? ────────────────────────────────
  lease_free=false

  if [ -z "$holder" ]; then
    lease_free=true
    log "Lease has no holder. Attempting acquisition..."
  elif [ -n "$renew_time" ]; then
    renew_epoch="$(parse_time "$renew_time")"
    now_epoch="$(epoch_seconds)"
    age=$((now_epoch - renew_epoch))
    if [ "$age" -gt "$LEASE_DURATION" ]; then
      lease_free=true
      log "Lease expired (age=${age}s > duration=${LEASE_DURATION}s, holder=$holder). Attempting acquisition..."
    fi
  else
    lease_free=true
    log "Lease has no renewTime. Attempting acquisition..."
  fi

  if [ "$lease_free" = "true" ]; then
    if try_acquire; then
      # Verify with a re-read to close the race window
      sleep 0.5
      if verify_holder; then
        become_active
        sleep "$RENEW_INTERVAL"
        continue
      else
        log "Lost acquisition race. Another pod claimed the lease."
        become_standby
      fi
    else
      log "Acquisition patch failed."
    fi
  else
    # Someone else holds a valid lease
    if [ "$current_role" != "standby" ]; then
      log "Another instance ($holder) holds the lease. Becoming standby."
      become_standby
    fi
  fi

  sleep "$RETRY_INTERVAL"
done
