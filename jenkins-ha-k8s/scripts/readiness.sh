#!/usr/bin/env bash
# readiness.sh — Returns 0 only if this pod is active AND Jenkins is responding.
# This keeps the standby pod out of the Service endpoints.

ROLE_FILE="${ROLE_FILE:-/var/run/jenkins-ha/role}"

role="$(cat "$ROLE_FILE" 2>/dev/null | tr -d '[:space:]')"

if [ "$role" != "active" ]; then
  # Standby pod — not ready (keeps it out of Service endpoints)
  exit 1
fi

# Active pod — check if Jenkins is actually responding
curl -sf -o /dev/null --max-time 5 http://localhost:8080/login 2>/dev/null
exit $?
