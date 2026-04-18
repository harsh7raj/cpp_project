#!/usr/bin/env bash
# helm-upgrade-demo.sh — Demonstrates successful Helm upgrades (criterion 4).
#
# Strategy: active-passive HA means the standby pod is intentionally
# NotReady (readinessProbe fails by design). This is incompatible with
# StatefulSet's default RollingUpdate + helm's --wait: both block forever
# because readyReplicas never reaches spec.replicas.
#
# Instead, the chart uses updateStrategy: OnDelete — `helm upgrade` only
# patches the spec, then this script orchestrates the pod rotation in
# HA-aware order:
#   1. Delete the STANDBY pod → recreated with new spec (zero downtime)
#   2. Delete the ACTIVE pod → triggers failover, recreated with new spec
#
# This is the SRE-standard approach for upgrading active-passive systems.

set -uo pipefail

NS="jenkins"
RELEASE="jenkins-ha"
CHART="helm/jenkins-ha"
LEASE="jenkins-leader"
LEASE_DURATION=15

# The value we toggle: jenkins.resources.limits.memory
OLD_MEM="1Gi"
NEW_MEM="1536Mi"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
BG_GREEN='\033[42m'
BG_RED='\033[41m'

log()  { echo -e "${CYAN}[$(date -u '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
fail() { echo -e "${RED}  ✗${NC} $*"; }

divider() {
  echo ""
  echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
  printf "${BOLD}║  %-67s║${NC}\n" "$1"
  echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

subdiv() {
  echo ""
  echo -e "${CYAN}┌───────────────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│${NC}  ${BOLD}$1${NC}"
  echo -e "${CYAN}└───────────────────────────────────────────────────────────────────────┘${NC}"
  echo ""
}

explain() {
  echo ""
  echo -e "${MAGENTA}  ┌─── 💡 WHAT'S HAPPENING ────────────────────────────────────────────┐${NC}"
  while IFS= read -r line; do
    echo -e "${MAGENTA}  │${NC}  $line"
  done <<< "$1"
  echo -e "${MAGENTA}  └──────────────────────────────────────────────────────────────────────┘${NC}"
  echo ""
}

pause_for_read() {
  local seconds=${1:-3}
  for ((i=seconds; i>0; i--)); do
    echo -ne "\r${DIM}  (continuing in ${i}s...)${NC}  "
    sleep 1
  done
  echo -ne "\r                            \r"
}

get_pod_memory() {
  local pod="$1"
  kubectl -n "$NS" get pod "$pod" \
    -o jsonpath='{.spec.containers[?(@.name=="jenkins")].resources.limits.memory}' 2>/dev/null
}

get_pod_uid() {
  kubectl -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null
}

get_active_pod() {
  kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=active \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

get_standby_pod() {
  kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=standby \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

pod_ready() {
  local pod="$1"
  local ready
  ready=$(kubectl -n "$NS" get pod "$pod" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="jenkins")].ready}' 2>/dev/null)
  [ "$ready" = "true" ]
}

pod_exists_with_uid_change() {
  # Returns 0 if pod exists AND its UID differs from the given prior UID.
  local pod="$1" prior_uid="$2"
  local cur_uid
  cur_uid=$(get_pod_uid "$pod")
  [ -n "$cur_uid" ] && [ "$cur_uid" != "$prior_uid" ]
}

get_chart_revision() {
  helm list -n "$NS" -o json 2>/dev/null \
    | grep -o '"revision":"[0-9]*"' \
    | head -n1 \
    | grep -o '[0-9]*'
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
divider "🚀 JENKINS HA HELM UPGRADE — LIVE DEMO"

echo -e "${BOLD}  This demo proves the 4th HA success criterion:${NC}"
echo -e "    ${GREEN}4.${NC} Successful Helm upgrades — config changes roll through"
echo -e "       the cluster in HA-aware order without data loss."
echo ""
echo -e "${DIM}  Strategy: updateStrategy=OnDelete${NC}"
echo -e "${DIM}    • helm upgrade only patches the StatefulSet spec (no auto-roll)${NC}"
echo -e "${DIM}    • We explicitly rotate pods: standby first, then force failover${NC}"
echo -e "${DIM}    • Matches real SRE practice for active-passive upgrades${NC}"
echo ""
echo -e "${DIM}  Test flow:${NC}"
echo -e "${DIM}    1. Capture pre-upgrade state${NC}"
echo -e "${DIM}    2. Write a marker file to prove data persistence${NC}"
echo -e "${DIM}    3. helm upgrade — patch the spec, change memory limit${NC}"
echo -e "${DIM}    4. Rotate STANDBY pod — zero-downtime, now on new spec${NC}"
echo -e "${DIM}    5. Rotate ACTIVE pod — triggers failover to the new-spec standby${NC}"
echo -e "${DIM}    6. Verify new memory on both pods + marker file survived${NC}"
echo -e "${DIM}    7. helm rollback + rotate — prove reversibility${NC}"
echo ""

log "Pre-flight checks..."

if ! helm status "$RELEASE" -n "$NS" &>/dev/null; then
  fail "Helm release '$RELEASE' not found in namespace '$NS'."
  echo "  Run 'make install' first."
  exit 1
fi
ok "Helm release '$RELEASE' found"

if ! kubectl -n "$NS" get statefulset jenkins &>/dev/null; then
  fail "StatefulSet 'jenkins' not found."
  exit 1
fi
ok "StatefulSet running"

UPDATE_STRATEGY=$(kubectl -n "$NS" get sts jenkins -o jsonpath='{.spec.updateStrategy.type}' 2>/dev/null)
if [ "$UPDATE_STRATEGY" = "OnDelete" ]; then
  ok "StatefulSet updateStrategy: OnDelete"
else
  warn "StatefulSet updateStrategy is '${UPDATE_STRATEGY}', expected 'OnDelete'."
  warn "Run 'make upgrade' first to apply the chart change that enables OnDelete."
  exit 1
fi

ACTIVE_POD=$(get_active_pod)
STANDBY_POD=$(get_standby_pod)
if [ -z "$ACTIVE_POD" ] || [ -z "$STANDBY_POD" ]; then
  fail "Expected one active + one standby pod. Got active='${ACTIVE_POD}' standby='${STANDBY_POD}'."
  exit 1
fi
ok "Active: ${ACTIVE_POD}  |  Standby: ${STANDBY_POD}"

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Capture pre-upgrade state
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 1 of 7 — Pre-Upgrade State"

PRE_REVISION=$(get_chart_revision)
PRE_MEM_0=$(get_pod_memory jenkins-0)
PRE_MEM_1=$(get_pod_memory jenkins-1)
PRE_UID_ACTIVE=$(get_pod_uid "$ACTIVE_POD")
PRE_UID_STANDBY=$(get_pod_uid "$STANDBY_POD")

explain "Starting state:
  • Helm revision:             ${PRE_REVISION}
  • jenkins-0 memory limit:    ${PRE_MEM_0}
  • jenkins-1 memory limit:    ${PRE_MEM_1}
  • Active pod:                ${ACTIVE_POD}
  • Standby pod:               ${STANDBY_POD}

We'll change jenkins.resources.limits.memory from ${OLD_MEM} → ${NEW_MEM}
and roll it through both pods in HA-aware order."

subdiv "Pod Status"
kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
echo ""

subdiv "Helm Release History"
helm history "$RELEASE" -n "$NS" --max 5
echo ""

pause_for_read 4

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Write marker
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 2 of 7 — Write Pre-Upgrade Marker File"

explain "We write a marker file on the current active pod. After BOTH pods
have rolled through the upgrade, we read it back — proving the RWX
PVC persists data across a full rolling restart."

MARKER_VALUE="upgrade-$(date +%s)"
log "Writing marker to ${BOLD}${ACTIVE_POD}${NC}..."
echo -e "  ${BOLD}File:${NC}   /var/jenkins_home/HA_UPGRADE_MARKER.txt"
echo -e "  ${BOLD}Value:${NC}  ${MARKER_VALUE}"
echo ""

kubectl -n "$NS" exec "$ACTIVE_POD" -c jenkins -- \
  bash -c "echo '${MARKER_VALUE}' > /var/jenkins_home/HA_UPGRADE_MARKER.txt" 2>/dev/null

READBACK=$(kubectl -n "$NS" exec "$ACTIVE_POD" -c jenkins -- \
  cat /var/jenkins_home/HA_UPGRADE_MARKER.txt 2>/dev/null || echo "FAILED")

if [ "$READBACK" = "$MARKER_VALUE" ]; then
  ok "Marker written on ${ACTIVE_POD}"
else
  fail "Could not write marker (${READBACK})"
  exit 1
fi

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: helm upgrade (patches spec, does NOT delete pods)
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 3 of 7 — 📦 helm upgrade (patch spec only)"

explain "Running:
  helm upgrade ${RELEASE} ${CHART} \\
    --namespace ${NS} \\
    --reuse-values \\
    --set jenkins.resources.limits.memory=${NEW_MEM}

Because updateStrategy=OnDelete, Helm only writes the new spec into
the StatefulSet's etcd object. No pods are touched. Existing pods
continue to serve traffic on the OLD memory limit until we delete them."

UPGRADE_START=$(date +%s)

if helm upgrade "$RELEASE" "$CHART" \
  --namespace "$NS" \
  --reuse-values \
  --set "jenkins.resources.limits.memory=${NEW_MEM}"; then
  UPGRADE_END=$(date +%s)
  UPGRADE_DURATION=$((UPGRADE_END - UPGRADE_START))
  echo ""
  ok "helm upgrade completed in ${UPGRADE_DURATION}s (spec patch only)"
else
  fail "helm upgrade failed"
  exit 1
fi

POST_REVISION=$(get_chart_revision)
ok "Helm revision: ${PRE_REVISION} → ${POST_REVISION}"

log "Confirming pods still on OLD memory (no auto-rotation happened)..."
STILL_OLD_0=$(get_pod_memory jenkins-0)
STILL_OLD_1=$(get_pod_memory jenkins-1)
echo -e "    jenkins-0: ${STILL_OLD_0}  (expected ${OLD_MEM} — unchanged)"
echo -e "    jenkins-1: ${STILL_OLD_1}  (expected ${OLD_MEM} — unchanged)"

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Rotate the STANDBY pod first (zero downtime)
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 4 of 7 — 🔄 Rotate STANDBY Pod (zero downtime)"

# Re-fetch in case the active/standby changed
ACTIVE_POD=$(get_active_pod)
STANDBY_POD=$(get_standby_pod)

explain "Deleting ${STANDBY_POD} (standby). The StatefulSet controller
recreates it using the current spec — which now has memory=${NEW_MEM}.
The active pod ${ACTIVE_POD} keeps serving traffic the whole time.
Zero downtime on this step."

PRE_UID_STANDBY=$(get_pod_uid "$STANDBY_POD")
log "Deleting ${STANDBY_POD} (UID=${PRE_UID_STANDBY})..."
kubectl -n "$NS" delete pod "$STANDBY_POD" --grace-period=30 --wait=false 2>&1 || true

log "Waiting for ${STANDBY_POD} to be recreated with a new UID..."
for i in $(seq 1 60); do
  if pod_exists_with_uid_change "$STANDBY_POD" "$PRE_UID_STANDBY"; then
    ok "${STANDBY_POD} recreated"
    break
  fi
  sleep 2
done

log "Waiting for leader-elector sidecar to label the new pod..."
for i in $(seq 1 30); do
  ROLE=$(kubectl -n "$NS" get pod "$STANDBY_POD" \
    -o jsonpath='{.metadata.labels.jenkins-role}' 2>/dev/null)
  [ -n "$ROLE" ] && break
  sleep 2
done

STEP4_MEM=$(get_pod_memory "$STANDBY_POD")
echo -e "  ${BOLD}${STANDBY_POD} memory:${NC}  ${STEP4_MEM}"
if [ "$STEP4_MEM" = "$NEW_MEM" ]; then
  ok "${STANDBY_POD} now on new memory limit (${NEW_MEM})"
else
  fail "${STANDBY_POD} still shows ${STEP4_MEM} (expected ${NEW_MEM})"
  exit 1
fi

subdiv "Pod Status (active still on old spec, standby on new spec)"
kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
echo ""

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Rotate the ACTIVE pod (triggers failover)
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 5 of 7 — 🔄 Rotate ACTIVE Pod (triggers failover)"

# Re-fetch in case anything flipped
ACTIVE_POD=$(get_active_pod)
STANDBY_POD=$(get_standby_pod)

explain "Deleting ${ACTIVE_POD} (active) forces a failover:
  • Lease renewals stop
  • After ~${LEASE_DURATION}s the standby ${STANDBY_POD} (already on new spec)
    detects expiry and acquires the Lease — becomes active
  • StatefulSet controller recreates ${ACTIVE_POD} with the new spec
  • New ${ACTIVE_POD} starts as standby (since ${STANDBY_POD} holds the Lease)

This is the ONE downtime window in the upgrade (~${LEASE_DURATION}-25s).
In production you'd schedule this during a maintenance window."

PRE_UID_ACTIVE=$(get_pod_uid "$ACTIVE_POD")
ORIGINAL_HOLDER=$(kubectl -n "$NS" get lease "$LEASE" \
  -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)

echo -e "  ${BG_RED}${BOLD}                                                    ${NC}"
echo -e "  ${BG_RED}${BOLD}   >>> DELETING ACTIVE ${ACTIVE_POD} — failover!    ${NC}"
echo -e "  ${BG_RED}${BOLD}                                                    ${NC}"
echo ""

log "Deleting ${ACTIVE_POD} (UID=${PRE_UID_ACTIVE}) with grace-period=0..."
kubectl -n "$NS" delete pod "$ACTIVE_POD" --grace-period=0 --force 2>&1 || true
KILL_TIME=$(date +%s)

log "Watching Lease for new holder (target: ≤ ${LEASE_DURATION}+10s)..."
echo ""

FAILOVER_TIME=0
for i in $(seq 1 30); do
  ELAPSED=$(( $(date +%s) - KILL_TIME ))
  HOLDER=$(kubectl -n "$NS" get lease "$LEASE" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || echo "")
  NEW_ACTIVE=$(get_active_pod)
  DISPLAY_HOLDER="${HOLDER%%/*}"

  echo -ne "  ${CYAN}[+${ELAPSED}s]${NC} Lease holder: ${BOLD}${DISPLAY_HOLDER:-<none>}${NC}    \r"

  if [ -n "$HOLDER" ] && [ "$HOLDER" != "$ORIGINAL_HOLDER" ] && [ -n "$NEW_ACTIVE" ]; then
    FAILOVER_TIME=$ELAPSED
    echo ""
    ok "New leader elected in ${FAILOVER_TIME}s: ${NEW_ACTIVE}"
    break
  fi
  sleep 2
done

echo ""

log "Waiting for ${ACTIVE_POD} (former active) to be recreated..."
for i in $(seq 1 60); do
  if pod_exists_with_uid_change "$ACTIVE_POD" "$PRE_UID_ACTIVE"; then
    ok "${ACTIVE_POD} recreated with new spec"
    break
  fi
  sleep 2
done

log "Waiting for the new active pod's Jenkins container to be Ready..."
NEW_ACTIVE=$(get_active_pod)
for i in $(seq 1 60); do
  if pod_ready "$NEW_ACTIVE"; then
    READY_AT=$(( $(date +%s) - KILL_TIME ))
    ok "${NEW_ACTIVE} is Ready at +${READY_AT}s"
    break
  fi
  sleep 2
done

subdiv "Pod Status (both now on new spec)"
kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
echo ""

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Verify memory + marker
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 6 of 7 — 🔍 Verify New Memory + Marker File Survived"

POST_MEM_0=$(get_pod_memory jenkins-0)
POST_MEM_1=$(get_pod_memory jenkins-1)

subdiv "Memory Limits After Upgrade"
echo -e "  ${BOLD}jenkins-0:${NC}  ${PRE_MEM_0}  →  ${POST_MEM_0}"
echo -e "  ${BOLD}jenkins-1:${NC}  ${PRE_MEM_1}  →  ${POST_MEM_1}"
echo ""

UPGRADE_OK=true
[ "$POST_MEM_0" = "$NEW_MEM" ] && ok "jenkins-0 → ${NEW_MEM}" || { fail "jenkins-0 = ${POST_MEM_0}"; UPGRADE_OK=false; }
[ "$POST_MEM_1" = "$NEW_MEM" ] && ok "jenkins-1 → ${NEW_MEM}" || { fail "jenkins-1 = ${POST_MEM_1}"; UPGRADE_OK=false; }

echo ""
NEW_ACTIVE=$(get_active_pod)
subdiv "Read marker from new active pod (${NEW_ACTIVE})"

FINAL_READ=$(kubectl -n "$NS" exec "$NEW_ACTIVE" -c jenkins -- \
  cat /var/jenkins_home/HA_UPGRADE_MARKER.txt 2>/dev/null || echo "FAILED")
echo -e "  ${BOLD}Expected:${NC}  ${MARKER_VALUE}"
echo -e "  ${BOLD}Actual:${NC}    ${FINAL_READ}"

MARKER_OK=false
if [ "$FINAL_READ" = "$MARKER_VALUE" ]; then
  echo ""
  echo -e "  ${BG_GREEN}${BOLD}   ✅ MARKER FILE SURVIVED THE UPGRADE!                     ${NC}"
  MARKER_OK=true
else
  fail "Marker mismatch"
fi

pause_for_read 4

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: Rollback
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 7 of 7 — ⏪ helm rollback (reverse rotation)"

explain "Running helm rollback ${RELEASE} ${PRE_REVISION} to restore the
previous spec (${OLD_MEM}). Same OnDelete strategy applies: helm patches
the spec, we rotate pods to apply it. For brevity, we rotate the
standby only and let the user manually delete the active if they want
to fully roll back (the spec is restored in etcd either way)."

ROLLBACK_START=$(date +%s)
if helm rollback "$RELEASE" "$PRE_REVISION" --namespace "$NS"; then
  ROLLBACK_END=$(date +%s)
  ok "helm rollback completed in $((ROLLBACK_END - ROLLBACK_START))s (spec restored)"
else
  fail "helm rollback failed"
  exit 1
fi

STANDBY_POD=$(get_standby_pod)
PRE_UID_STANDBY=$(get_pod_uid "$STANDBY_POD")

log "Rotating standby ${STANDBY_POD} to pick up rolled-back spec..."
kubectl -n "$NS" delete pod "$STANDBY_POD" --grace-period=30 --wait=false 2>&1 || true

for i in $(seq 1 60); do
  if pod_exists_with_uid_change "$STANDBY_POD" "$PRE_UID_STANDBY"; then
    break
  fi
  sleep 2
done

sleep 5  # let the new pod stabilize
RESTORED_MEM=$(get_pod_memory "$STANDBY_POD")
echo -e "  ${BOLD}${STANDBY_POD} memory after rollback:${NC}  ${RESTORED_MEM}"

ROLLBACK_OK=false
if [ "$RESTORED_MEM" = "$OLD_MEM" ]; then
  ok "Rollback rotation verified: ${STANDBY_POD} → ${OLD_MEM}"
  ROLLBACK_OK=true
else
  warn "${STANDBY_POD} shows ${RESTORED_MEM} (expected ${OLD_MEM})"
fi

echo ""
echo -e "  ${DIM}Note: the ACTIVE pod is still on ${NEW_MEM} until you manually${NC}"
echo -e "  ${DIM}delete it. Run:  kubectl -n ${NS} delete pod \$(kubectl -n ${NS} get pod${NC}"
echo -e "  ${DIM}                -l app=jenkins,jenkins-role=active -o name)${NC}"
echo -e "  ${DIM}to complete the rollback with one more failover.${NC}"

pause_for_read 4

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
divider "📊 UPGRADE DEMO — FINAL SCORECARD"

echo ""
echo -e "  ${BOLD}  Test 1: helm upgrade applied new value to both pods${NC}"
if [ "$UPGRADE_OK" = true ]; then
  echo -e "     ${GREEN}✅ PASS${NC} — jenkins.resources.limits.memory = ${NEW_MEM} on all pods"
else
  echo -e "     ${RED}❌ FAIL${NC}"
fi
echo ""
echo -e "  ${BOLD}  Test 2: Data survived the rolling upgrade${NC}"
if [ "$MARKER_OK" = true ]; then
  echo -e "     ${GREEN}✅ PASS${NC} — Marker file intact after both pods rotated"
else
  echo -e "     ${RED}❌ FAIL${NC}"
fi
echo ""
echo -e "  ${BOLD}  Test 3: helm rollback restored the previous spec${NC}"
if [ "$ROLLBACK_OK" = true ]; then
  echo -e "     ${GREEN}✅ PASS${NC} — Standby pod restored to ${OLD_MEM} after rollback"
else
  echo -e "     ${YELLOW}⚠ PARTIAL${NC} — Standby rotated; active still on ${NEW_MEM}"
fi

echo ""
echo -e "  ${BOLD}  Failover timing during upgrade:${NC}"
echo -e "     Lease transfer:   ${FAILOVER_TIME}s"
echo -e "     New active Ready: +${READY_AT:-?}s"
echo ""

subdiv "Helm Release History (final)"
helm history "$RELEASE" -n "$NS" --max 8
echo ""

subdiv "Final Pod Status"
kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
echo ""

echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════${NC}"
log "Upgrade demo complete!"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════${NC}"
echo ""
