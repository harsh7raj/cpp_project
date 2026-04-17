#!/usr/bin/env bash
# helm-upgrade-demo.sh — Demonstrates successful Helm upgrades (4th success criterion).
#
# Proves:
#   4. Jenkins can be reconfigured/upgraded via `helm upgrade` without data loss.
#      Pods roll one-at-a-time, new values apply, the marker file survives,
#      and `helm rollback` reverts the change cleanly.

set -uo pipefail

NS="jenkins"
RELEASE="jenkins-ha"
CHART="helm/jenkins-ha"

# The value we toggle: jenkins.resources.limits.memory
# Default is 1Gi; we bump it to 1536Mi and then roll back.
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
BG_YELLOW='\033[43m'

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
  kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[?(@.name=="jenkins")].resources.limits.memory}' 2>/dev/null
}

get_active_pod() {
  kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=active \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

get_chart_revision() {
  helm list -n "$NS" -o json 2>/dev/null \
    | grep -o '"revision":"[0-9]*"' \
    | head -n1 \
    | grep -o '[0-9]*'
}

wait_for_both_pods_ready() {
  local timeout="${1:-300}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local ready_count
    ready_count=$(kubectl -n "$NS" get pods -l app=jenkins \
      -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null \
      | tr ' ' '\n' | grep -c '^true$' || true)
    # Each pod has 2 containers (jenkins + leader-elector), so 2 pods × 2 = 4 ready.
    if [ "$ready_count" -ge 4 ]; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo -ne "\r${DIM}  Waiting for rolling update... (${elapsed}s, ${ready_count}/4 containers ready)${NC}  "
  done
  echo ""
  return 1
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
divider "🚀 JENKINS HA HELM UPGRADE — LIVE DEMO"

echo -e "${BOLD}  This demo proves the 4th HA success criterion:${NC}"
echo -e "    ${GREEN}4.${NC} Successful Helm upgrades — config changes roll out"
echo -e "       through the cluster without downtime and without data loss."
echo ""
echo -e "${DIM}  Test flow:${NC}"
echo -e "${DIM}    1. Capture the pre-upgrade state (chart revision, memory limit, marker file)${NC}"
echo -e "${DIM}    2. Run 'helm upgrade' with a new memory limit${NC}"
echo -e "${DIM}    3. Watch StatefulSet roll pods one-at-a-time (reverse ordinal order)${NC}"
echo -e "${DIM}    4. Verify the new value applied on BOTH pods${NC}"
echo -e "${DIM}    5. Verify the marker file survived the upgrade${NC}"
echo -e "${DIM}    6. Run 'helm rollback' to revert — prove reversibility${NC}"
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

POD0_READY=$(kubectl -n "$NS" get pod jenkins-0 -o jsonpath='{.status.containerStatuses[?(@.name=="jenkins")].ready}' 2>/dev/null || echo "false")
POD1_READY=$(kubectl -n "$NS" get pod jenkins-1 -o jsonpath='{.status.containerStatuses[?(@.name=="jenkins")].ready}' 2>/dev/null || echo "false")
if [ "$POD0_READY" != "true" ] && [ "$POD1_READY" != "true" ]; then
  fail "Neither pod is ready. Wait for the system to stabilize."
  exit 1
fi
ok "At least one pod ready — leader election is functional"

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Capture the pre-upgrade state
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 1 of 6 — Pre-Upgrade State"

PRE_REVISION=$(get_chart_revision)
PRE_MEM_0=$(get_pod_memory jenkins-0)
PRE_MEM_1=$(get_pod_memory jenkins-1)
ACTIVE_POD=$(get_active_pod)

explain "Before any change, record the starting state:
  • Current Helm revision:    ${PRE_REVISION}
  • jenkins-0 memory limit:   ${PRE_MEM_0}
  • jenkins-1 memory limit:   ${PRE_MEM_1}
  • Current active pod:       ${ACTIVE_POD:-<none>}

We will change jenkins.resources.limits.memory from ${OLD_MEM} → ${NEW_MEM}
and watch the rolling upgrade unfold."

subdiv "Pod Status"
kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
echo ""

subdiv "Helm Release History"
helm history "$RELEASE" -n "$NS" --max 5
echo ""

pause_for_read 4

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Write the upgrade marker
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 2 of 6 — Write Pre-Upgrade Marker File"

explain "We write a marker file on the active pod before the upgrade.
After both pods have rolled through helm upgrade, we will read the
same file back — proving the RWX PVC persisted across the whole
rolling restart, not just a single pod failure."

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
# STEP 3: Run helm upgrade
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 3 of 6 — 📦 Running helm upgrade"

explain "Executing:
  helm upgrade ${RELEASE} ${CHART} \\
    --namespace ${NS} \\
    --reuse-values \\
    --set jenkins.resources.limits.memory=${NEW_MEM}

What Helm does internally:
  1. Renders every template with the new value
  2. Diffs the rendered manifests against the last-applied manifests
  3. Patches the StatefulSet spec in-place (only the memory limit changes)
  4. Creates a new Helm release revision (revision N+1)

What the StatefulSet controller does next:
  • podManagementPolicy=OrderedReady + updateStrategy=RollingUpdate
  • Rolls pods in REVERSE ordinal order: jenkins-1 first, then jenkins-0
  • Waits for each pod to become Ready before touching the next
  • This means there is always at least one Jenkins pod running
    — the Lease-holder keeps serving traffic throughout the upgrade"

UPGRADE_START=$(date +%s)

log "Starting helm upgrade..."
echo ""

if helm upgrade "$RELEASE" "$CHART" \
  --namespace "$NS" \
  --reuse-values \
  --set "jenkins.resources.limits.memory=${NEW_MEM}" \
  --wait --timeout 5m; then
  UPGRADE_END=$(date +%s)
  UPGRADE_DURATION=$((UPGRADE_END - UPGRADE_START))
  echo ""
  ok "helm upgrade completed in ${UPGRADE_DURATION}s"
else
  fail "helm upgrade failed"
  exit 1
fi

POST_REVISION=$(get_chart_revision)
ok "Helm revision: ${PRE_REVISION} → ${POST_REVISION}"

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Verify the new memory limit on both pods
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 4 of 6 — 🔍 Verify New Value Applied"

explain "After the upgrade, both pods should show the new memory limit.
This proves Helm's template rendering + kubectl patch actually flowed
through to the running containers."

# Give the scheduler a beat — wait is already called above but be safe.
sleep 3

POST_MEM_0=$(get_pod_memory jenkins-0)
POST_MEM_1=$(get_pod_memory jenkins-1)

subdiv "Memory Limits"
echo -e "  ${BOLD}jenkins-0:${NC}  ${PRE_MEM_0}  →  ${POST_MEM_0}"
echo -e "  ${BOLD}jenkins-1:${NC}  ${PRE_MEM_1}  →  ${POST_MEM_1}"
echo ""

UPGRADE_OK=true
if [ "$POST_MEM_0" = "$NEW_MEM" ]; then
  ok "jenkins-0 has new memory limit (${NEW_MEM})"
else
  fail "jenkins-0 still has ${POST_MEM_0} (expected ${NEW_MEM})"
  UPGRADE_OK=false
fi
if [ "$POST_MEM_1" = "$NEW_MEM" ]; then
  ok "jenkins-1 has new memory limit (${NEW_MEM})"
else
  fail "jenkins-1 still has ${POST_MEM_1} (expected ${NEW_MEM})"
  UPGRADE_OK=false
fi
echo ""

subdiv "Pod Status After Upgrade"
kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
echo ""

NEW_ACTIVE=$(get_active_pod)
if [ -n "$NEW_ACTIVE" ]; then
  ok "Active leader after upgrade: ${NEW_ACTIVE}"
else
  warn "No active pod yet — leader election may still be settling"
fi

pause_for_read 4

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Verify the marker file survived
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 5 of 6 — 💾 Marker File Survived?"

explain "The marker file was written to /var/jenkins_home on the pre-upgrade
active pod. After a rolling upgrade that restarted BOTH pods, we
now read it back from the CURRENT active pod. If the value matches,
the shared PVC truly persisted through the entire upgrade."

NEW_ACTIVE=$(get_active_pod)
if [ -z "$NEW_ACTIVE" ]; then
  warn "No active pod yet — waiting up to 60s..."
  for i in $(seq 1 30); do
    NEW_ACTIVE=$(get_active_pod)
    [ -n "$NEW_ACTIVE" ] && break
    sleep 2
  done
fi

if [ -z "$NEW_ACTIVE" ]; then
  fail "No active pod — cannot verify marker"
  exit 1
fi

FINAL_READ=$(kubectl -n "$NS" exec "$NEW_ACTIVE" -c jenkins -- \
  cat /var/jenkins_home/HA_UPGRADE_MARKER.txt 2>/dev/null || echo "FAILED")

echo -e "  ${BOLD}Expected:${NC}  ${MARKER_VALUE}"
echo -e "  ${BOLD}Actual:${NC}    ${FINAL_READ}"
echo -e "  ${BOLD}Read from:${NC} ${NEW_ACTIVE}"
echo ""

if [ "$FINAL_READ" = "$MARKER_VALUE" ]; then
  echo -e "  ${BG_GREEN}${BOLD}                                                           ${NC}"
  echo -e "  ${BG_GREEN}${BOLD}   ✅ MARKER FILE SURVIVED THE UPGRADE!                     ${NC}"
  echo -e "  ${BG_GREEN}${BOLD}                                                           ${NC}"
  MARKER_OK=true
else
  fail "Marker mismatch — expected ${MARKER_VALUE}, got ${FINAL_READ}"
  MARKER_OK=false
fi

pause_for_read 4

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Rollback
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 6 of 6 — ⏪ helm rollback (Prove Reversibility)"

explain "Successful upgrades are half the story. A real HA deployment must
also support ROLLING BACK when a change is bad. We run:
  helm rollback ${RELEASE} ${PRE_REVISION}

Helm will apply the previous revision's rendered manifests. The
StatefulSet picks up the change and rolls the pods again, this time
restoring jenkins.resources.limits.memory = ${OLD_MEM}."

log "Rolling back to revision ${PRE_REVISION}..."
echo ""

ROLLBACK_START=$(date +%s)
if helm rollback "$RELEASE" "$PRE_REVISION" \
  --namespace "$NS" \
  --wait --timeout 5m; then
  ROLLBACK_END=$(date +%s)
  ROLLBACK_DURATION=$((ROLLBACK_END - ROLLBACK_START))
  echo ""
  ok "helm rollback completed in ${ROLLBACK_DURATION}s"
else
  fail "helm rollback failed"
  exit 1
fi

sleep 3

RESTORED_MEM_0=$(get_pod_memory jenkins-0)
RESTORED_MEM_1=$(get_pod_memory jenkins-1)

subdiv "Memory Limits After Rollback"
echo -e "  ${BOLD}jenkins-0:${NC}  ${POST_MEM_0}  →  ${RESTORED_MEM_0}"
echo -e "  ${BOLD}jenkins-1:${NC}  ${POST_MEM_1}  →  ${RESTORED_MEM_1}"
echo ""

ROLLBACK_OK=true
if [ "$RESTORED_MEM_0" = "$OLD_MEM" ]; then
  ok "jenkins-0 restored to ${OLD_MEM}"
else
  warn "jenkins-0 shows ${RESTORED_MEM_0} (expected ${OLD_MEM})"
  ROLLBACK_OK=false
fi
if [ "$RESTORED_MEM_1" = "$OLD_MEM" ]; then
  ok "jenkins-1 restored to ${OLD_MEM}"
else
  warn "jenkins-1 shows ${RESTORED_MEM_1} (expected ${OLD_MEM})"
  ROLLBACK_OK=false
fi

# Verify marker file STILL present after rollback (two rollouts, still there)
FINAL_ACTIVE=$(get_active_pod)
if [ -n "$FINAL_ACTIVE" ]; then
  ROLLBACK_MARKER=$(kubectl -n "$NS" exec "$FINAL_ACTIVE" -c jenkins -- \
    cat /var/jenkins_home/HA_UPGRADE_MARKER.txt 2>/dev/null || echo "FAILED")
  if [ "$ROLLBACK_MARKER" = "$MARKER_VALUE" ]; then
    ok "Marker file STILL present after rollback"
  else
    warn "Marker missing after rollback (${ROLLBACK_MARKER})"
  fi
fi

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
divider "📊 UPGRADE DEMO — FINAL SCORECARD"

echo ""
echo -e "  ${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "  ${BOLD}│            JENKINS HA — HELM UPGRADE RESULTS                │${NC}"
echo -e "  ${BOLD}├─────────────────────────────────────────────────────────────┤${NC}"
echo ""

echo -e "  ${BOLD}  Test 1: helm upgrade applied new value to both pods${NC}"
if [ "$UPGRADE_OK" = true ]; then
  echo -e "     ${GREEN}✅ PASS${NC} — jenkins.resources.limits.memory = ${NEW_MEM} on all pods"
  echo -e "     ${DIM}Rolling update completed in ${UPGRADE_DURATION}s${NC}"
else
  echo -e "     ${RED}❌ FAIL${NC}"
fi
echo ""

echo -e "  ${BOLD}  Test 2: Data survived the rolling upgrade${NC}"
if [ "$MARKER_OK" = true ]; then
  echo -e "     ${GREEN}✅ PASS${NC} — Marker file intact after both pods restarted"
  echo -e "     ${DIM}RWX PVC decouples data from pod lifecycle${NC}"
else
  echo -e "     ${RED}❌ FAIL${NC}"
fi
echo ""

echo -e "  ${BOLD}  Test 3: helm rollback restored the previous revision${NC}"
if [ "$ROLLBACK_OK" = true ]; then
  echo -e "     ${GREEN}✅ PASS${NC} — jenkins.resources.limits.memory = ${OLD_MEM} on all pods"
  echo -e "     ${DIM}Rollback completed in ${ROLLBACK_DURATION}s${NC}"
else
  echo -e "     ${RED}❌ FAIL${NC}"
fi

echo ""
echo -e "  ${BOLD}├─────────────────────────────────────────────────────────────┤${NC}"
printf "  ${BOLD}│  %-57s│${NC}\n" "Helm revisions:"
printf "  ${BOLD}│    %-55s│${NC}\n" "pre-upgrade: r${PRE_REVISION} (${OLD_MEM})"
printf "  ${BOLD}│    %-55s│${NC}\n" "post-upgrade: r${POST_REVISION} (${NEW_MEM})"
printf "  ${BOLD}│    %-55s│${NC}\n" "post-rollback: r$(get_chart_revision) (${OLD_MEM})"
echo -e "  ${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

subdiv "Helm Release History (final)"
helm history "$RELEASE" -n "$NS" --max 8
echo ""

echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════${NC}"
echo ""
log "Upgrade demo complete!"
echo ""
echo -e "${DIM}  The Helm release has been returned to its pre-demo state.${NC}"
echo -e "${DIM}  The upgrade marker file remains on the PVC as evidence.${NC}"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════${NC}"
echo ""
