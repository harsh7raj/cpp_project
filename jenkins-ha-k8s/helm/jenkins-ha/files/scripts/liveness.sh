#!/usr/bin/env bash
# liveness.sh — Role-aware liveness probe.
# Standby pods: always return success (Jenkins is intentionally not running).
# Active pods: check that Jenkins responds on /login.

ROLE_FILE="${ROLE_FILE:-/var/run/jenkins-ha/role}"

role="$(cat "$ROLE_FILE" 2>/dev/null | tr -d '[:space:]')"

if [ "$role" != "active" ]; then
  # Standby — the guard process is alive but Jenkins is not; that's expected.
  exit 0
fi

# Active — Jenkins should be responding.
curl -sf -o /dev/null --max-time 5 http://localhost:8080/login 2>/dev/null
exit $?
