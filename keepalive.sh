#!/usr/bin/env bash
# =============================================================================
# keepalive.sh - periodically touches every file under $WORK so a time-based
# /tmp reaper doesn't sweep it up during an idle stretch. Runs as a svc.sh
# service ("keepalive"); has no port and nothing to connect to - check it's
# alive with `svc status` / `svc logs keepalive`.
#
# Does NOT protect against a node reboot or a hard /tmp clear - only against
# "untouched for N days" style reapers.
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/00-env.sh"

if [[ "$(hostname -s)" != "$HPC_GPU_NODE" ]]; then
  printf '\033[1;31m[FATAL]\033[0m You are on '\''%s'\''. This must run on '\''%s'\''.\n' \
    "$(hostname -s)" "$HPC_GPU_NODE" >&2
  exit 1
fi

echo "keepalive: touching \$WORK every ${HPC_KEEPALIVE_INTERVAL}s (pid $$)"
while true; do
  find "$WORK" -depth -exec touch -a {} + 2>/dev/null
  echo "$(date -Is) touched $(find "$WORK" 2>/dev/null | wc -l) paths under \$WORK"
  sleep "$HPC_KEEPALIVE_INTERVAL"
done
