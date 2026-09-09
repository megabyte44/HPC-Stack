#!/usr/bin/env bash
# =============================================================================
# coder-idle-watch.sh - auto-stops the `coder` vLLM instance (qwen3-coder-480b)
# after CODER_IDLE_TIMEOUT seconds with no requests. vLLM has no built-in
# idle-unload (KNOWLEDGE.md §5.9b) - this is the "human or a cron/watchdog
# you'd have to build yourself" that note anticipated.
#
# Runs as the "coder-watch" svc.sh service. Not meant to be run by hand -
# coder-ctl.sh starts/stops it alongside coder itself. Idleness is measured
# via vLLM's own /metrics (request counters), not log timestamps - vLLM logs
# periodic stats lines even with zero traffic, which would make a
# log-mtime-based check never fire.
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/00-env.sh"

log() { printf '[coder-watch %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

METRICS_URL="http://127.0.0.1:${CODER_PORT}/metrics"
last_active=$(date +%s)
last_count=-1

log "watching coder for idleness (timeout=${CODER_IDLE_TIMEOUT}s, poll=${CODER_POLL_INTERVAL}s)"

while true; do
  sleep "$CODER_POLL_INTERVAL"

  # coder itself is gone (stopped by hand, crashed, or a previous idle-stop) - nothing left to watch
  if [[ ! -f "$HPC_RUN/coder.pid" ]] || ! kill -0 "$(cat "$HPC_RUN/coder.pid" 2>/dev/null)" 2>/dev/null; then
    log "coder is not running - exiting watcher"
    exit 0
  fi

  metrics="$(curl -fsS -m 5 "$METRICS_URL" 2>/dev/null)"
  if [[ -z "$metrics" ]]; then
    log "couldn't reach $METRICS_URL (still loading, or a transient blip) - not counting this as idle time"
    continue
  fi

  running="$(printf '%s' "$metrics" | awk '/^vllm:num_requests_running/{s+=$NF} END{print s+0}')"
  finished="$(printf '%s' "$metrics" | awk '/^vllm:request_success_total/{s+=$NF} END{print s+0}')"

  now=$(date +%s)
  if [[ "$running" != "0" ]] || [[ "$finished" != "$last_count" ]]; then
    last_active=$now
    last_count=$finished
    continue
  fi

  idle_for=$(( now - last_active ))
  if (( idle_for >= CODER_IDLE_TIMEOUT )); then
    log "idle for ${idle_for}s (>= ${CODER_IDLE_TIMEOUT}s) - stopping coder"
    "$(dirname "$0")/svc.sh" stop coder
    log "coder stopped, GPUs released. Run 'coder start' to bring it back."
    exit 0
  fi
done
