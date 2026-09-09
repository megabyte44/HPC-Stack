#!/usr/bin/env bash
# =============================================================================
# comfyui-idle-watch.sh - releases GPU1's VRAM after ComfyUI's queue has sat
# empty for COMFYUI_IDLE_TIMEOUT, without stopping the ComfyUI process/UI.
#
# ComfyUI is not like `coder`: its process is cheap to leave running (no
# boot-time model commit), it lazy-loads models per workflow - but it also
# caches whatever it loaded in VRAM indefinitely between generations, with
# no idle-unload of its own (confirmed via /system_stats: ~54GB resident on
# GPU1 with an empty queue). ComfyUI exposes a real API for this
# (server.py: POST /free {"unload_models": true, "free_memory": true}) -
# this script just calls it once the queue has been idle long enough.
# Next generation reloads whatever it needs, same as any first run.
#
# Runs as the "comfyui-watch" svc.sh service. Start it any time comfyui is
# up: `svc start comfyui-watch` (safe to arm on an already-running comfyui,
# no restart needed).
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/00-env.sh"

log() { printf '[comfyui-watch %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

QUEUE_URL="http://127.0.0.1:${COMFYUI_PORT}/queue"
FREE_URL="http://127.0.0.1:${COMFYUI_PORT}/free"
idle_since=$(date +%s)
already_freed=0

log "watching comfyui's queue (idle timeout=${COMFYUI_IDLE_TIMEOUT}s, poll=${COMFYUI_POLL_INTERVAL}s)"

while true; do
  sleep "$COMFYUI_POLL_INTERVAL"

  if [[ ! -f "$HPC_RUN/comfyui.pid" ]] || ! kill -0 "$(cat "$HPC_RUN/comfyui.pid" 2>/dev/null)" 2>/dev/null; then
    log "comfyui is not running - exiting watcher"
    exit 0
  fi

  queue="$(curl -fsS -m 5 "$QUEUE_URL" 2>/dev/null)"
  if [[ -z "$queue" ]]; then
    log "couldn't reach $QUEUE_URL (transient blip?) - not counting this as idle time"
    continue
  fi

  # busy if either list has entries beyond the empty-array marker
  if ! grep -q '"queue_running": \[\], "queue_pending": \[\]' <<<"$queue" \
     && ! grep -q '"queue_running":\[\],"queue_pending":\[\]' <<<"$queue"; then
    idle_since=$(date +%s)
    already_freed=0
    continue
  fi

  now=$(date +%s)
  idle_for=$(( now - idle_since ))
  if (( idle_for >= COMFYUI_IDLE_TIMEOUT )) && (( already_freed == 0 )); then
    log "queue idle for ${idle_for}s (>= ${COMFYUI_IDLE_TIMEOUT}s) - releasing VRAM via POST /free"
    if curl -fsS -m 10 -X POST "$FREE_URL" -H 'Content-Type: application/json' \
         -d '{"unload_models": true, "free_memory": true}' >/dev/null 2>&1; then
      log "freed. GPU1 VRAM released, comfyui process/UI still up."
      already_freed=1
    else
      log "POST /free failed - will retry next idle window"
    fi
  fi
done
