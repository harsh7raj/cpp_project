#!/usr/bin/env bash
# ui-demo.sh — Browser-based failover walkthrough.
#
# Unlike demo-failover.sh (terminal-only, fully automated), this script is
# designed to be run ALONGSIDE a browser at http://localhost:8080.
#
# Usage:
#   Terminal 1:  make ui-port-forward        # keep running, auto-reconnects
#   Browser:     http://localhost:8080       # sign in, view a job
#   Terminal 2:  make ui-demo                # this script — waits at each step
#
# The script pauses at each step so you can narrate + show the UI to the
# audience. At every pause it prints exactly what to do in the browser.

set -uo pipefail

NS="jenkins"
LEASE="jenkins-leader"
LEASE_DURATION=15

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'

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

browser_instructions() {
  echo ""
  echo -e "${BLUE}  ┌─── 🌐 IN THE BROWSER ───────────────────────────────────────────────┐${NC}"
  while IFS= read -r line; do
    echo -e "${BLUE}  │${NC}  $line"
  done <<< "$1"
  echo -e "${BLUE}  └──────────────────────────────────────────────────────────────────────┘${NC}"
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

press_enter() {
  echo ""
  echo -ne "${BOLD}${YELLOW}  → Press ENTER when you're ready to continue...${NC}"
  read -r _
  echo ""
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
divider "🌐 JENKINS HA — BROWSER FAILOVER DEMO"

echo -e "${BOLD}  This is a GUIDED, INTERACTIVE demo. Unlike make failover-test,${NC}"
echo -e "${BOLD}  this script pauses at each step so you can narrate in the UI.${NC}"
echo ""
echo -e "${BOLD}  Expected setup (BEFORE you run this script):${NC}"
echo ""
echo -e "    ${GREEN}Terminal 1:${NC}  ${BOLD}make ui-port-forward${NC}"
echo -e "                    (endpoint-gated — keeps port 8080 DOWN until a"
echo -e "                    Ready active pod exists, for a clean visual effect)"
echo ""
echo -e "    ${GREEN}Browser:${NC}    ${BOLD}Open a PRIVATE / INCOGNITO window${NC} at http://localhost:8080"
echo -e "                    Or open DevTools → Network tab → check 'Disable cache'"
echo -e "                    (This prevents Jenkins static assets from being"
echo -e "                    served from cache during the crash window, which"
echo -e "                    would otherwise make the UI look falsely 'up'.)"
echo -e "                    Sign in → the Jenkins dashboard should be visible"
echo ""
echo -e "    ${GREEN}Terminal 2:${NC}  this script (${BOLD}make ui-demo${NC})"
echo ""

log "Pre-flight checks..."

if ! kubectl -n "$NS" get statefulset jenkins &>/dev/null; then
  fail "StatefulSet 'jenkins' not found. Run 'make install' first."
  exit 1
fi
ok "StatefulSet found"

if ! nc -z localhost 8080 2>/dev/null; then
  warn "Port 8080 not listening locally."
  warn "Did you start 'make ui-port-forward' in Terminal 1? (continuing anyway)"
else
  ok "Port 8080 is listening → UI reachable at http://localhost:8080"
fi

ACTIVE_POD=$(kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=active \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
STANDBY_POD=$(kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=standby \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
ORIGINAL_HOLDER=$(kubectl -n "$NS" get lease "$LEASE" \
  -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)

if [ -z "$ACTIVE_POD" ]; then
  fail "No active pod. Wait for the cluster to stabilize."
  exit 1
fi
ok "Active leader:  ${BOLD}${ACTIVE_POD}${NC}"
ok "Hot standby:    ${BOLD}${STANDBY_POD}${NC}"

press_enter

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Show the cluster state, set up the browser
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 1 of 5 — Show the Healthy Cluster"

subdiv_banner() {
  echo -e "${CYAN}┌───────────────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│${NC}  ${BOLD}$1${NC}"
  echo -e "${CYAN}└───────────────────────────────────────────────────────────────────────┘${NC}"
}

subdiv_banner "Cluster state (terminal)"
echo ""
kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
echo ""

explain "Both pods exist. Only ${ACTIVE_POD} is running Jenkins and serving
the UI. ${STANDBY_POD} is a hot standby — its Jenkins process is
blocked by the guard script until it wins the Lease."

browser_instructions "If not already signed in: go to http://localhost:8080
Sign in with your admin account. You should see the Jenkins dashboard.
Show the audience:
  • The top bar (Jenkins logo, your username)
  • The empty job list (or an existing job)
  • The 'Manage Jenkins' link — proves admin access"

press_enter

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Create a job in the UI
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 2 of 5 — Create a Job + Build"

browser_instructions "In the browser, create a slow job so we can watch it persist:

  1. Click ${BOLD}+ New Item${NC} (top-left sidebar)
  2. Name it: ${BOLD}ha-demo-job${NC}
  3. Pick ${BOLD}Freestyle project${NC} → OK
  4. Under 'Build Steps' → Add build step → ${BOLD}Execute shell${NC}
  5. Paste:
       ${BOLD}echo \"build running on \$(hostname)\"${NC}
       ${BOLD}for i in 1 2 3 4 5 6 7 8 9 10; do echo \"tick \$i\"; sleep 2; done${NC}
       ${BOLD}echo \"build complete\"${NC}
  6. Save
  7. Click ${BOLD}Build Now${NC} in the sidebar
  8. Click the build number in 'Build History' → Console Output

  KEEP THE CONSOLE OUTPUT PAGE OPEN. It auto-refreshes.

  TELL THE AUDIENCE: 'This job is running on jenkins-0. It writes its
  state (builds/, lastBuild, config.xml) to /var/jenkins_home on the
  shared PVC — so jenkins-1 will be able to see it after failover.'"

press_enter

# Verify the job exists on the pod (optional sanity check)
log "Sanity check: is the job config on the PVC?"
if kubectl -n "$NS" exec "$ACTIVE_POD" -c jenkins -- \
     test -d "/var/jenkins_home/jobs/ha-demo-job" 2>/dev/null; then
  ok "jobs/ha-demo-job/ exists on the PVC"
else
  warn "Didn't find jobs/ha-demo-job — did you create it with that exact name?"
  warn "Continuing anyway — the demo still works with any existing job."
fi

press_enter

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Crash the active pod
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 3 of 5 — 💥 Crash the Active Pod"

explain "About to force-delete ${ACTIVE_POD}. What the audience will see:

  • In the BROWSER: ERR_CONNECTION_REFUSED on refresh. The page will
    be fully unreachable for the entire failover window — no cached
    HTML flickers, no half-loaded states. The endpoint-gated
    port-forward keeps localhost:8080 closed until the NEW leader's
    Jenkins container reports Ready.

  • In TERMINAL 1: you'll see
        '⚠ Tunnel to ${ACTIVE_POD} dropped — UI is now DOWN...'
        '⏳ No Ready active pod — waiting for leader to come up...'
    until the new leader is Ready, at which point it prints
        '✓ Leader Ready (jenkins-1) — opening tunnel on :8080'

  • In this TERMINAL: we poll the Lease every 2s. Expected timeline:
        +0s   pod deleted, Lease renewals stop
        +15s  Lease expires, standby acquires it
        +17s  guard script on new leader starts Jenkins
        +25-30s  Jenkins readiness probe passes, tunnel re-opens

Tell the audience BEFORE killing the pod:
  'Watch the browser. The UI is about to go completely dark — not
  flickering, not partially loaded. After about ${LEASE_DURATION}s the standby
  notices the Lease has gone stale and claims it. Jenkins then takes
  another 10-15s to start up on the new leader. The moment Jenkins
  is Ready, the browser works again — one clean down-to-up transition.'"

press_enter

echo -e "  ${BG_RED}${BOLD}                                                    ${NC}"
echo -e "  ${BG_RED}${BOLD}   >>> CRASHING ${ACTIVE_POD} NOW <<<               ${NC}"
echo -e "  ${BG_RED}${BOLD}                                                    ${NC}"
echo ""

log "Force-deleting ${ACTIVE_POD} (--grace-period=0 --force)..."
kubectl -n "$NS" delete pod "$ACTIVE_POD" --grace-period=0 --force 2>&1 || true
KILL_TIME=$(date +%s)
ok "Pod deleted. Lease renewals have stopped."

browser_instructions "RIGHT NOW, switch to the browser and hit REFRESH.

Expected: ${BOLD}ERR_CONNECTION_REFUSED${NC} (Chrome) /
          ${BOLD}Unable to connect${NC} (Firefox) /
          ${BOLD}Safari can't connect to the server${NC} (Safari).

Show the audience this error page. Explain:
  'The port-forward in Terminal 1 has detected that no active pod
  exists, so it's keeping localhost:8080 fully closed. No cached
  assets are being served, no partial page — the UI is genuinely
  unreachable. This is the worst-case downtime window.'

This window lasts ~${LEASE_DURATION}-25s total."

echo ""
log "Polling Lease every 2s until a new holder emerges..."
echo ""

FAILOVER_DETECTED=false
FAILOVER_TIME=0

for i in $(seq 1 25); do
  ELAPSED=$(( $(date +%s) - KILL_TIME ))

  NEW_ACTIVE=$(kubectl -n "$NS" get pod -l app=jenkins,jenkins-role=active \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  HOLDER=$(kubectl -n "$NS" get lease "$LEASE" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || echo "???")

  DISPLAY_HOLDER="${HOLDER%%/*}"

  PHASE=""
  if [ -z "$HOLDER" ] || [ "$HOLDER" = "null" ]; then
    PHASE="${YELLOW}⏳ Lease VACANT — pods racing${NC}"
  elif [ "$HOLDER" = "$ORIGINAL_HOLDER" ]; then
    PHASE="${YELLOW}⏳ Old holder still listed — waiting for lease expiry${NC}"
  else
    PHASE="${GREEN}🏆 NEW holder: ${DISPLAY_HOLDER}${NC}"
  fi

  echo -e "${CYAN}  [+${ELAPSED}s]${NC} Lease: ${BOLD}${DISPLAY_HOLDER:-<VACANT>}${NC}  ${PHASE}"

  if [ -n "$HOLDER" ] && [ "$HOLDER" != "$ORIGINAL_HOLDER" ] && [ -n "$NEW_ACTIVE" ]; then
    FAILOVER_TIME=$ELAPSED
    FAILOVER_DETECTED=true
    echo ""
    echo -e "  ${BG_GREEN}${BOLD}                                                        ${NC}"
    echo -e "  ${BG_GREEN}${BOLD}   🎉 New leader elected in ${FAILOVER_TIME}s: ${NEW_ACTIVE}     ${NC}"
    echo -e "  ${BG_GREEN}${BOLD}                                                        ${NC}"
    break
  fi

  sleep 2
done

if [ "$FAILOVER_DETECTED" = false ]; then
  fail "Lease leadership did not transfer within 50s. Check sidecar logs."
  exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Wait for Jenkins to be ready + UI to come back
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 4 of 5 — Wait for Jenkins Ready on New Leader"

explain "The Lease has transferred, but Jenkins itself is still starting
on ${NEW_ACTIVE}. We poll the readinessProbe endpoint (port 8080)
inside the pod until it returns. Typically 10-15s for a warm JVM."

log "Waiting for ${NEW_ACTIVE} to report Ready..."

READY_AT=0
for i in $(seq 1 30); do
  ELAPSED=$(( $(date +%s) - KILL_TIME ))
  READY=$(kubectl -n "$NS" get pod "$NEW_ACTIVE" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="jenkins")].ready}' 2>/dev/null || echo "false")
  if [ "$READY" = "true" ]; then
    READY_AT=$ELAPSED
    echo ""
    ok "${NEW_ACTIVE} is Ready at +${ELAPSED}s"
    break
  fi
  echo -e "  ${DIM}[+${ELAPSED}s] ${NEW_ACTIVE} not ready yet...${NC}"
  sleep 2
done

if [ "$READY_AT" -eq 0 ]; then
  warn "Pod not Ready within 60s — it may still be starting. Check the UI."
fi

browser_instructions "Check Terminal 1 — it should now show:
  '✓ Leader Ready (${NEW_ACTIVE}) — opening tunnel on :8080'

SWITCH BACK TO THE BROWSER and hit REFRESH (F5 / Cmd-R).

The UI transitions cleanly from ERR_CONNECTION_REFUSED → dashboard
loaded. No in-between state. Show the audience:
  • Jenkins dashboard returns — on a DIFFERENT pod
  • Navigate to ${BOLD}ha-demo-job${NC} in the job list — IT'S STILL THERE
  • Click the build — the config + previous build history SURVIVED
    (the console output will show 'aborted' since the executor died
    with the old pod — but the build record itself is intact)
  • Click ${BOLD}Build Now${NC} again to prove the new leader can run jobs

TELL THE AUDIENCE:
  'Single clean transition. No flicker, no cached artefacts — the
  UI was genuinely unreachable for ~${READY_AT}s, then immediately
  fully functional on a different pod. The job's config, its history,
  the user database, plugins — everything is on the shared PVC and
  completely intact. Zero data loss.'"

press_enter

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Wrap-up
# ══════════════════════════════════════════════════════════════════════════════
divider "STEP 5 of 5 — Summary"

TOTAL_DOWNTIME=$READY_AT
if [ "$TOTAL_DOWNTIME" -eq 0 ]; then TOTAL_DOWNTIME=$FAILOVER_TIME; fi

echo ""
echo -e "  ${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "  ${BOLD}│         JENKINS HA — BROWSER DEMO SCORECARD                │${NC}"
echo -e "  ${BOLD}├─────────────────────────────────────────────────────────────┤${NC}"
echo ""
echo -e "  Old active pod:       ${BOLD}${ACTIVE_POD}${NC} (crashed)"
echo -e "  New active pod:       ${BOLD}${NEW_ACTIVE}${NC}"
echo -e "  Lease transfer time:  ${BOLD}${FAILOVER_TIME}s${NC}"
echo -e "  Jenkins Ready again:  ${BOLD}+${READY_AT}s${NC}  (total UI downtime)"
echo -e "  Target SLA:           ≤ 30s"
echo ""
if [ "$TOTAL_DOWNTIME" -le 30 ]; then
  echo -e "  ${GREEN}${BOLD}✅ WITHIN SLA${NC}"
else
  echo -e "  ${YELLOW}${BOLD}⚠  OVER SLA${NC} — investigate Jenkins startup time"
fi
echo ""
echo -e "  ${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

subdiv_banner "Final Cluster State"
echo ""
kubectl -n "$NS" get pods -l app=jenkins -L jenkins-role -o wide
echo ""

log "Demo complete. The Service endpoints have already shifted."
echo -e "${DIM}  Keep 'make ui-port-forward' running for Q&A —${NC}"
echo -e "${DIM}  it will reconnect to whichever pod is currently active.${NC}"
echo ""
