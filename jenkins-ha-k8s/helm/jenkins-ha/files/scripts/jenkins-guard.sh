#!/usr/bin/env bash
# jenkins-guard.sh — Wraps the Jenkins entrypoint.
# Waits until the sidecar declares this pod "active" before starting Jenkins.
# If the role flips back to "standby", SIGTERMs Jenkins to prevent split-brain writes.

set -uo pipefail

ROLE_FILE="${ROLE_FILE:-/var/run/jenkins-ha/role}"
POLL_INTERVAL="${GUARD_POLL_INTERVAL:-2}"
JENKINS_PID=""

log() { echo "[guard] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

get_role() {
  if [ -f "$ROLE_FILE" ]; then
    cat "$ROLE_FILE" 2>/dev/null | tr -d '[:space:]'
  else
    echo "standby"
  fi
}

start_jenkins() {
  log "Starting Jenkins..."
  # Run Jenkins in the background so we can monitor the role file
  /usr/local/bin/jenkins.sh &
  JENKINS_PID=$!
  log "Jenkins started with PID=$JENKINS_PID"
}

stop_jenkins() {
  if [ -n "$JENKINS_PID" ] && kill -0 "$JENKINS_PID" 2>/dev/null; then
    log "Stopping Jenkins (PID=$JENKINS_PID)..."
    kill -TERM "$JENKINS_PID" 2>/dev/null || true
    # Wait up to 30 seconds for graceful shutdown
    local count=0
    while kill -0 "$JENKINS_PID" 2>/dev/null && [ "$count" -lt 30 ]; do
      sleep 1
      count=$((count + 1))
    done
    if kill -0 "$JENKINS_PID" 2>/dev/null; then
      log "Jenkins did not stop gracefully, sending SIGKILL..."
      kill -9 "$JENKINS_PID" 2>/dev/null || true
    fi
    log "Jenkins stopped."
    JENKINS_PID=""
  fi
}

cleanup() {
  log "Caught termination signal."
  stop_jenkins
  exit 0
}

trap cleanup SIGTERM SIGINT

# ── Main loop ────────────────────────────────────────────────────────────────
log "Guard starting. Watching role file: $ROLE_FILE"
log "Waiting for role=active..."

jenkins_running=false

while true; do
  role="$(get_role)"

  if [ "$role" = "active" ]; then
    if [ "$jenkins_running" = false ]; then
      start_jenkins
      jenkins_running=true
    fi

    # Check if Jenkins process is still alive
    if [ -n "$JENKINS_PID" ] && ! kill -0 "$JENKINS_PID" 2>/dev/null; then
      log "Jenkins process died unexpectedly. Restarting..."
      jenkins_running=false
      JENKINS_PID=""
      # Brief pause before restart
      sleep 2
      continue
    fi
  else
    # Role is standby (or unknown)
    if [ "$jenkins_running" = true ]; then
      log "Role changed to '$role'. Shutting down Jenkins to prevent split-brain."
      stop_jenkins
      jenkins_running=false
    fi
  fi

  sleep "$POLL_INTERVAL"
done
