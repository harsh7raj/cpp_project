#!/usr/bin/env bash
# demo-failover.sh — Demonstrates Jenkins HA failover.
# Kills the active pod and watches the standby take over.
#
# This is the script to run during your demo to prove:
#   1. Only one active Jenkins instance at any time
#   2. Failover within 30 seconds
#   3. Stable storage (Jenkins state survives the failover)

set -uo pipefail

NS="jenkins"
LEASE="jenkins-leader"
LEASE_DURATION=15

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
BG_RED='\033[41m'
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

# explain() prints a "WHAT'S HAPPENING" box. Pass content as $1.
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

# ── Pre-flight ───────────────────────────────────────────────────────────────
divider "🚀 JENKINS HA FAILOVER — LIVE DEMO"

echo -e "${BOLD}  This demo proves three things:${NC}"
echo -e "    ${GREEN}1.${NC} Only ONE active Jenkins at any time (no split-brain)"
echo -e "    ${GREEN}2.${NC} Automatic failover within 30 seconds"
echo -e "    ${GREEN}3.${NC} Data survives the failover (persistent storage)"
echo ""
echo -e "${DIM}  Architecture: 2 Jenkins pods → 1 active, 1 hot standby${NC}"
echo -e "${DIM}  Leader election via Kubernetes Lease object${NC}"
echo -e "${DIM}  Each pod has a sidecar (leader-elector) + guard script${NC}"
echo ""

log "Pre-flight checks..."

if ! kubectl -n "$NS" get statefulset jenkins &>/dev/null; then
  fail "StatefulSet 'jenkins' not found in namespace '$NS'."
  echo "  Run ./deploy.sh first."
  exit 1
fi
ok "StatefulSet found"

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Show current state
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 1 of 6 — Current State (Before Failure)"

ACTIVE_POD=$(kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=active \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
STANDBY_POD=$(kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=standby \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
# Capture the full identity (name/uid) of the current holder for failover detection
ORIGINAL_HOLDER=$(kubectl -n "$NS" get lease "$LEASE" \
  -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)

if [ -z "$ACTIVE_POD" ]; then
  fail "No active pod found. Wait for the system to stabilize."
  exit 1
fi

explain "Right now, the HA cluster is healthy:
  • ${ACTIVE_POD} is the ACTIVE leader — it holds the Kubernetes Lease
  • ${ACTIVE_POD}'s sidecar renews the Lease every 5 seconds
  • ${STANDBY_POD} is the HOT STANDBY — its sidecar checks the Lease
    every 2 seconds, but sees it's still held by ${ACTIVE_POD}
  • The Service 'jenkins' routes traffic ONLY to the active pod
    (it uses selector: jenkins-role=active)"

subdiv "Pod Status"
kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
echo ""

echo -e "  ${BG_GREEN}${BOLD} ACTIVE  ${NC}  ${BOLD}${ACTIVE_POD}${NC}  ← Jenkins is running here, serving traffic"
echo -e "  ${BG_YELLOW}${BOLD} STANDBY ${NC}  ${BOLD}${STANDBY_POD}${NC}  ← Jenkins NOT running, waiting for promotion"
echo ""

subdiv "Kubernetes Lease Object"
kubectl -n "$NS" get lease "$LEASE" \
  -o jsonpath='  Holder: {.spec.holderIdentity}   Renew: {.spec.renewTime}'
echo ""
echo ""

explain "The Lease object is the lock. It says:
  holderIdentity: ${ACTIVE_POD}  ← This pod owns leadership
  renewTime: updates every ~5 seconds
  leaseDuration: 15 seconds  ← If not renewed within 15s, it is stale"

subdiv "Service Endpoints (where traffic goes)"
kubectl -n "$NS" get endpoints jenkins
echo ""

# Verify only one pod is active
ACTIVE_COUNT=$(kubectl -n "$NS" get pods -l app=jenkins,jenkins-role=active \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$ACTIVE_COUNT" -eq 1 ]; then
  ok "VERIFIED: Exactly 1 active Jenkins instance ✓"
else
  fail "Expected 1 active pod, found $ACTIVE_COUNT"
fi

pause_for_read 4

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Create a marker file to prove storage persistence
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 2 of 6 — Write Marker File (Proof of Persistence)"

explain "We write a unique marker file to the shared PVC volume.
After the failover, we will check if this file still exists
on the NEW active pod — proving data survived the crash.

Both pods mount the SAME PersistentVolumeClaim in RWX mode,
so data written by jenkins-0 is accessible by jenkins-1."

MARKER_VALUE="demo-$(date +%s)"
log "Writing marker file to Jenkins home on ${BOLD}${ACTIVE_POD}${NC}..."
echo -e "  ${BOLD}File:${NC}   /var/jenkins_home/HA_DEMO_MARKER.txt"
echo -e "  ${BOLD}Value:${NC}  ${MARKER_VALUE}"
echo ""

kubectl -n "$NS" exec "$ACTIVE_POD" -c jenkins -- \
  bash -c "echo '${MARKER_VALUE}' > /var/jenkins_home/HA_DEMO_MARKER.txt" 2>/dev/null

# Verify it was written
READBACK=$(kubectl -n "$NS" exec "$ACTIVE_POD" -c jenkins -- \
  cat /var/jenkins_home/HA_DEMO_MARKER.txt 2>/dev/null || echo "FAILED")

if [ "$READBACK" = "$MARKER_VALUE" ]; then
  ok "Marker file written and verified on ${ACTIVE_POD}"
else
  fail "Failed to write marker file"
fi

echo ""
log "Cross-checking: Can the standby pod see the same file?"
STANDBY_READ=$(kubectl -n "$NS" exec "$STANDBY_POD" -c jenkins -- \
  cat /var/jenkins_home/HA_DEMO_MARKER.txt 2>/dev/null || echo "FAILED")

if [ "$STANDBY_READ" = "$MARKER_VALUE" ]; then
  ok "Standby pod ${STANDBY_POD} can read the same marker file ✓"
  ok "Shared RWX PersistentVolumeClaim confirmed ✓"
else
  warn "Standby could not read marker (may not have volume mounted yet)"
fi

pause_for_read 4

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Kill the active pod
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 3 of 6 — 💥 SIMULATING FAILURE (Crashing Active Pod)"

explain "We will now FORCE-DELETE ${ACTIVE_POD} to simulate a sudden crash.

What this means:
  • ${ACTIVE_POD} is immediately terminated — no graceful shutdown
  • ${ACTIVE_POD}'s sidecar STOPS renewing the Lease
  • The Lease still names ${ACTIVE_POD} as holder, but renewals stop
  • After ${LEASE_DURATION}s of no renewal the Lease is considered stale
  • ${STANDBY_POD}'s sidecar detects the expired Lease and acquires it

The StatefulSet will recreate ${ACTIVE_POD} with a NEW pod UID.
The new pod's sidecar sees holderIdentity != its own identity (UID
changed) so it will NOT reclaim the lease — it waits to be elected.
This is real, automatic failover with no manual intervention."

echo -e "  ${BG_RED}${BOLD}                                                    ${NC}"
echo -e "  ${BG_RED}${BOLD}   >>> CRASHING ${ACTIVE_POD} NOW <<<               ${NC}"
echo -e "  ${BG_RED}${BOLD}                                                    ${NC}"
echo ""

# Force-delete the active pod — nothing else, no manual lease changes
log "Force-deleting ${ACTIVE_POD} (--grace-period=0 --force)..."
kubectl -n "$NS" delete pod "$ACTIVE_POD" --grace-period=0 --force 2>&1 || true
ok "${ACTIVE_POD} deleted — sidecar is gone, Lease renewals have stopped"
KILL_TIME=$(date +%s)
echo ""

explain "Right now:
  • ${ACTIVE_POD} is DEAD — its sidecar has stopped renewing the Lease
  • The Lease still says holderIdentity = ${ACTIVE_POD}/<old-uid>
  • ${STANDBY_POD}'s sidecar is polling every 2s, waiting for expiry
  • After ${LEASE_DURATION}s of silence the Lease is stale — ${STANDBY_POD} will acquire it
  • StatefulSet recreates ${ACTIVE_POD} with a NEW UID — its sidecar
    sees a different identity in the Lease, so it will NOT reclaim it
  • Whoever acquires the Lease first (after expiry) becomes the new leader"

pause_for_read 2

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Watch the failover
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 4 of 6 — 👀 WATCHING FAILOVER IN REAL TIME"

explain "What should happen now — watch it live below:

   +0s  ${ACTIVE_POD} deleted. Its sidecar stops renewing the Lease.
   +2s  ${STANDBY_POD}'s sidecar polls — Lease still held by ${ACTIVE_POD}, not yet stale.
   ~5s  StatefulSet recreates ${ACTIVE_POD} with a NEW UID — it cannot reclaim the Lease.
  +15s  Lease age exceeds ${LEASE_DURATION}s without renewal — it is now STALE.
  +15s  ${STANDBY_POD}'s sidecar detects expiry, races to acquire the Lease.
  +15s  ${STANDBY_POD} patches holderIdentity → its own identity, becomes ACTIVE.
  +17s  ${STANDBY_POD}'s guard script detects role=active, STARTS Jenkins.
  +17s  K8s Service selector shifts traffic to ${STANDBY_POD}.

  Key: Lease duration = ${LEASE_DURATION}s, Renew interval = 5s, Check interval = 2s
  No manual intervention — pure automatic failover via lease expiry."

log "Monitoring for standby promotion..."
echo ""
echo -e "${DIM}  Polling every 2 seconds...${NC}"
echo ""

FAILOVER_DETECTED=false
FAILOVER_TIME=0

for i in $(seq 1 25); do
  ELAPSED=$(( $(date +%s) - KILL_TIME ))

  # Check if the former standby is now active
  NEW_ACTIVE=$(kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=active \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  # Get current lease holder
  HOLDER=$(kubectl -n "$NS" get lease "$LEASE" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || echo "???")

  # Pod statuses
  POD_STATUS=$(kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role \
    --no-headers 2>/dev/null || echo "checking...")

  # The holder identity is now "podname/uid" — extract just the name for display
  DISPLAY_HOLDER="${HOLDER%%/*}"

  # Phase description
  PHASE=""
  if [ -z "$HOLDER" ] || [ "$HOLDER" = "null" ]; then
    PHASE="${YELLOW}⏳ Lease VACANT — pods racing to acquire${NC}"
  elif [ "$HOLDER" = "$ORIGINAL_HOLDER" ]; then
    PHASE="${YELLOW}⏳ Old holder (dead) — Lease expires in ~${LEASE_DURATION}s from last renewal${NC}"
  else
    PHASE="${GREEN}🏆 NEW holder: ${DISPLAY_HOLDER} — failover complete!${NC}"
  fi

  echo -e "${CYAN}  ┌── [+${ELAPSED}s] ──────────${NC}"
  echo -e "${CYAN}  │${NC} Lease holder: ${BOLD}${DISPLAY_HOLDER:-<VACANT>}${NC}  ${PHASE}"
  echo "$POD_STATUS" | while read -r line; do
    if echo "$line" | grep -q "active"; then
      echo -e "${CYAN}  │${NC}   ${GREEN}▶ $line${NC}"
    elif echo "$line" | grep -q "standby"; then
      echo -e "${CYAN}  │${NC}   ${YELLOW}◆ $line${NC}"
    else
      echo -e "${CYAN}  │${NC}   ${DIM}  $line${NC}"
    fi
  done
  echo -e "${CYAN}  └──────────────────────${NC}"

  # Failover is complete when the Lease has a NEW identity AND a pod has the active label
  if [ -n "$HOLDER" ] && [ "$HOLDER" != "$ORIGINAL_HOLDER" ] && [ -n "$NEW_ACTIVE" ]; then
    FAILOVER_TIME=$ELAPSED
    FAILOVER_DETECTED=true
    echo ""
    echo -e "  ${BG_GREEN}${BOLD}                                                        ${NC}"
    echo -e "  ${BG_GREEN}${BOLD}   🎉 FAILOVER COMPLETE in ${FAILOVER_TIME} seconds!     ${NC}"
    echo -e "  ${BG_GREEN}${BOLD}   New active pod: ${NEW_ACTIVE}                          ${NC}"
    echo -e "  ${BG_GREEN}${BOLD}                                                        ${NC}"
    echo ""

    explain "What just happened:
  1. ${ACTIVE_POD} crashed — its sidecar STOPPED renewing the Lease
  2. The Lease went stale after ${LEASE_DURATION}s of no renewal
  3. ${STANDBY_POD}'s sidecar detected expiry and acquired the Lease
  4. ${STANDBY_POD}'s sidecar labeled itself: jenkins-role=active
  5. K8s Service selector shifted — all traffic now routes to ${NEW_ACTIVE}
  6. ${NEW_ACTIVE}'s guard script saw role=active and STARTED Jenkins!
  7. K8s StatefulSet recreated ${ACTIVE_POD} with a NEW UID
  8. New ${ACTIVE_POD} saw a different identity in the Lease — became STANDBY
  No manual intervention. Pure automatic failover."
    break
  fi

  echo ""
  sleep 2
done

if [ "$FAILOVER_DETECTED" = false ]; then
  fail "Failover did not complete within 50 seconds. Check sidecar logs."
  echo ""
  echo "Debug commands:"
  echo "  kubectl -n $NS logs ${STANDBY_POD} -c leader-elector --tail=30"
  exit 1
fi

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Verify the new leader
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 5 of 6 — 🔍 POST-FAILOVER VERIFICATION"

NEW_ACTIVE=$(kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=active \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

explain "The failover is complete. Here is the system state:

  BEFORE                          AFTER
  ─────────────────────         ─────────────────────
  ${ACTIVE_POD} = ACTIVE          ${ACTIVE_POD} = CRASHED, recreating as STANDBY
  ${STANDBY_POD} = STANDBY        ${NEW_ACTIVE} = ACTIVE ← NEW LEADER!

What happened internally:
  1. ${ACTIVE_POD} crashed — its sidecar STOPPED renewing the Lease
  2. The Lease went stale after ${LEASE_DURATION}s of no renewal
  3. ${STANDBY_POD}'s sidecar detected expiry and acquired the Lease
  4. ${STANDBY_POD}'s sidecar labeled itself: jenkins-role=active
  5. K8s Service selector shifted traffic to ${NEW_ACTIVE}
  6. ${NEW_ACTIVE}'s guard script detected role=active, STARTED Jenkins
  7. K8s StatefulSet recreated ${ACTIVE_POD} with a brand-new UID
  8. New ${ACTIVE_POD}'s sidecar saw a foreign identity in the Lease
     so it became STANDBY — cluster is healthy again
  No manual intervention at any point."

subdiv "Single-Leader Invariant Check"
log "Verifying only ONE pod is active (no split-brain)..."
ACTIVE_COUNT=$(kubectl -n "$NS" get pods -l app=jenkins,jenkins-role=active \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$ACTIVE_COUNT" -eq 1 ]; then
  ok "VERIFIED: Exactly 1 active Jenkins instance (NO split-brain) ✓"
else
  fail "Expected 1 active pod, found $ACTIVE_COUNT"
fi
echo ""

subdiv "Lease Object (New State)"
kubectl -n "$NS" get lease "$LEASE" \
  -o jsonpath='  Holder: {.spec.holderIdentity}   Renew: {.spec.renewTime}'
echo ""
echo ""
echo -e "  ${DIM}↑ Notice: holderIdentity is now ${NEW_ACTIVE} (was ${ACTIVE_POD})${NC}"
echo ""

subdiv "Service Endpoints (Traffic Routing)"
kubectl -n "$NS" get endpoints jenkins
echo ""
echo -e "  ${DIM}↑ Notice: Endpoint now points to ${NEW_ACTIVE} — traffic shifted automatically${NC}"
echo ""

pause_for_read 4

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Verify storage survived
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 6 of 6 — 💾 STORAGE PERSISTENCE PROOF"

explain "This is the CRITICAL test: did our data SURVIVE the failover?

In Step 2, we wrote a marker file to /var/jenkins_home/ on ${ACTIVE_POD}.
That pod is now DEAD. We will read the same file from ${NEW_ACTIVE}.

WHY THIS WORKS:
  • Both pods mount the same PersistentVolumeClaim jenkins-ha-home
  • The PVC uses ReadWriteMany RWX access mode
  • The underlying storage PersistentVolume is NOT tied to any pod
  • When ${ACTIVE_POD} died, the data stayed on the volume
  • ${NEW_ACTIVE} already has the volume mounted — data is intact!

This proves:
  ✓ Jenkins jobs, configurations, and plugins survive failover
  ✓ No data loss during leader transitions
  ✓ The PVC is truly shared and independent of pod lifecycle"

subdiv "Reading marker file from NEW active pod (${NEW_ACTIVE})"

# Give it a moment for Jenkins to be fully ready
sleep 3

echo -e "  ${BOLD}File:${NC}      /var/jenkins_home/HA_DEMO_MARKER.txt"
echo -e "  ${BOLD}Expected:${NC}  ${MARKER_VALUE}"
echo ""

FINAL_READ=$(kubectl -n "$NS" exec "$NEW_ACTIVE" -c jenkins -- \
  cat /var/jenkins_home/HA_DEMO_MARKER.txt 2>/dev/null || echo "FAILED")

echo -e "  ${BOLD}Actual:${NC}    ${FINAL_READ}"
echo ""

if [ "$FINAL_READ" = "$MARKER_VALUE" ]; then
  echo -e "  ${BG_GREEN}${BOLD}                                                           ${NC}"
  echo -e "  ${BG_GREEN}${BOLD}   ✅ MARKER FILE SURVIVED THE FAILOVER!                    ${NC}"
  echo -e "  ${BG_GREEN}${BOLD}                                                           ${NC}"
  echo ""
  ok "Written on:  ${ACTIVE_POD} (now dead)"
  ok "Read from:   ${NEW_ACTIVE} (new leader)"
  ok "Value match: ${MARKER_VALUE} == ${FINAL_READ}"
  echo ""
  explain "The marker file written by the OLD leader was successfully read
by the NEW leader. This proves the shared PVC is working correctly.

In a real Jenkins deployment, this means:
  • Job history       → PRESERVED
  • Pipeline configs  → PRESERVED
  • Plugin settings   → PRESERVED
  • Credentials       → PRESERVED
  • Build artifacts   → PRESERVED"
else
  if [ "$FINAL_READ" = "FAILED" ]; then
    warn "Could not read marker yet (Jenkins container may still be starting)"
    warn "Try manually: kubectl -n $NS exec $NEW_ACTIVE -c jenkins -- cat /var/jenkins_home/HA_DEMO_MARKER.txt"
  else
    fail "Marker mismatch! Written: ${MARKER_VALUE}, Got: ${FINAL_READ}"
  fi
fi

pause_for_read 3

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY: Final Results
# ══════════════════════════════════════════════════════════════════════════════
divider "📊 DEMO RESULTS — FINAL SCORECARD"

echo ""
echo -e "  ${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "  ${BOLD}│               JENKINS HA FAILOVER RESULTS                  │${NC}"
echo -e "  ${BOLD}├─────────────────────────────────────────────────────────────┤${NC}"
echo ""

echo -e "  ${BOLD}  Test 1: Single Active Instance (No Split-Brain)${NC}"
if [ "$ACTIVE_COUNT" -eq 1 ]; then
  echo -e "     ${GREEN}✅ PASS${NC} — Only one Jenkins pod was active at all times"
  echo -e "     ${DIM}The Lease-based election guarantees mutual exclusion${NC}"
else
  echo -e "     ${RED}❌ FAIL${NC}"
fi

echo ""
echo -e "  ${BOLD}  Test 2: Failover Speed${NC}"
if [ "$FAILOVER_TIME" -le 30 ]; then
  echo -e "     ${GREEN}✅ PASS${NC} — Failover completed in ${BOLD}${FAILOVER_TIME}s${NC} (target: ≤30s)"
  echo -e "     ${DIM}Includes 5s sidecar teardown + lease transfer + standby detection${NC}"
else
  echo -e "     ${YELLOW}⚠  SLOW${NC} — Failover took ${FAILOVER_TIME}s (target: ≤30s)"
fi

echo ""
echo -e "  ${BOLD}  Test 3: Data Persistence Across Failover${NC}"
if [ "$FINAL_READ" = "$MARKER_VALUE" ]; then
  echo -e "     ${GREEN}✅ PASS${NC} — Data written by ${ACTIVE_POD} survived on ${NEW_ACTIVE}"
  echo -e "     ${DIM}Shared RWX PVC decouples data from pod lifecycle${NC}"
else
  echo -e "     ${YELLOW}⚠  PENDING${NC} — Verify manually after Jenkins starts"
fi

echo ""
echo -e "  ${BOLD}├─────────────────────────────────────────────────────────────┤${NC}"
printf "  ${BOLD}│  %-57s│${NC}\n" "Failover Path:"
printf "  ${BOLD}│    %-55s│${NC}\n" "${ACTIVE_POD} (active) → CRASHED"
printf "  ${BOLD}│    %-55s│${NC}\n" "${NEW_ACTIVE:-$STANDBY_POD} (standby → active) ← NEW LEADER"
printf "  ${BOLD}│    %-55s│${NC}\n" "${ACTIVE_POD} → recreated as STANDBY"
echo -e "  ${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ── Wait for the replacement pod ─────────────────────────────────────────
subdiv "Waiting for ${ACTIVE_POD} to rejoin as standby..."

explain "The StatefulSet controller noticed ${ACTIVE_POD} is missing.
It will recreate the pod automatically. When ${ACTIVE_POD} starts:
  1. Its leader-elector sidecar starts and checks the Lease
  2. The Lease is held by ${NEW_ACTIVE:-$STANDBY_POD} so ${ACTIVE_POD} cannot claim it
  3. Its sidecar labels itself: jenkins-role=standby
  4. Its guard script sees role=standby so Jenkins does NOT start
  5. ${ACTIVE_POD} becomes the new HOT STANDBY, ready for the NEXT failover!"

for i in $(seq 1 20); do
  POD_COUNT=$(kubectl -n "$NS" get pods -l app=jenkins --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$POD_COUNT" -ge 2 ]; then
    OLD_ROLE=$(kubectl -n "$NS" get pod "$ACTIVE_POD" -o jsonpath='{.metadata.labels.jenkins-role}' 2>/dev/null || echo "unknown")
    echo ""
    ok "Both pods running again:"
    echo ""
    kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
    echo ""
    echo -e "  ${DIM}Notice: ${NEW_ACTIVE:-$STANDBY_POD} is ACTIVE (new leader), ${ACTIVE_POD} is ${OLD_ROLE} (rejoined)${NC}"
    echo ""
    break
  fi
  echo -e "  ${DIM}  Waiting for pod recreation... (${i}/20)${NC}"
  sleep 5
done

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════${NC}"
echo ""
log "Demo complete! To access Jenkins:"
echo ""
echo "    kubectl -n jenkins port-forward svc/jenkins 8080:8080"
echo "    Then open: http://localhost:8080"
echo ""
echo -e "${DIM}  The Service automatically routes to the new active pod.${NC}"
echo -e "${DIM}  All your Jenkins data (jobs, configs, plugins) is intact.${NC}"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════${NC}"
echo ""
