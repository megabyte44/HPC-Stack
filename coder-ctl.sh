#!/usr/bin/env bash
# =============================================================================
# coder-ctl.sh - on-demand start/stop for qwen3-coder-480b, with automatic
# idle-timeout shutdown so it doesn't permanently pin 4 H200s.
#
#   coder start     # picks free GPUs fresh, launches vLLM, waits for ready
#   coder status     # up/down, which GPUs, health, idle-watch state
#   coder stop      # stops coder + its idle watcher, releases the GPUs
#
# (bashrc-snippet.sh aliases 'coder' to this script)
#
# IMPORTANT - read before relying on this: Slurm is installed cluster-wide
# but is NOT usable for dgx-node1. `scontrol show node dgx-node1` returns
# "not found" - Slurm's actual configured nodes are gpunode1/gpunode2,
# different physical machines, both currently drained/invalid, and
# dgx-node1 has neither slurmd nor munge installed. So there is no
# scheduler here to request an allocation from. What this script does
# instead - a fresh nvidia-smi free-GPU pick at every start - is the exact
# same discipline every other user on this shared box already practices by
# hand (see KNOWLEDGE.md §5.6); this script just does it automatically and
# consistently instead of you doing it manually each time. It is NOT
# scheduler-enforced isolation. See KNOWLEDGE.md §4a for the full writeup.
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/00-env.sh"

log() { printf '\033[1;35m[coder]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[coder]\033[0m %s\n' "$*" >&2; }

[[ "$(hostname -s)" == "$HPC_GPU_NODE" ]] || exec ssh -t "$HPC_GPU_NODE" "bash \$HOME/hpc-stack/coder-ctl.sh $*"

SELF_DIR="$(dirname "$(readlink -f "$0")")"

is_coder_up() {
  [[ -f "$HPC_RUN/coder.pid" ]] && kill -0 "$(cat "$HPC_RUN/coder.pid" 2>/dev/null)" 2>/dev/null
}

# GPUs dedicated to another always-on service - never pick these even if
# they show plenty of free memory right now. comfyui only uses its GPU
# during an actual generation (KNOWLEDGE.md §4a.1), so it can look
# deceptively idle between jobs; colocating a huge LLM there would starve
# whichever one loads second the next time both are active.
reserved_gpus() {
  local out=""
  if [[ -f "$HPC_RUN/comfyui.pid" ]] && kill -0 "$(cat "$HPC_RUN/comfyui.pid" 2>/dev/null)" 2>/dev/null; then
    out="$(tr '\0' '\n' < "/proc/$(cat "$HPC_RUN/comfyui.pid")/environ" 2>/dev/null | grep '^CUDA_VISIBLE_DEVICES=' | cut -d= -f2)"
  fi
  echo "$out"
}

# Picks N GPUs by real headroom, not a flat "touched at all" threshold -
# a GPU qualifies if it has >= CODER_GPU_MIN_FREE_MIB free AND its compute
# utilization is <= CODER_GPU_MAX_UTIL_PCT (skips a GPU someone is actively
# computing on even if memory would fit), and isn't in reserved_gpus; among
# qualifying GPUs, the ones with the most free memory are picked first.
# Doesn't care whose usage it is, ours or another user's - never touches a
# GPU that doesn't qualify. Prints nothing and returns fewer than needed
# if not enough qualify; caller must check count.
pick_free_gpus() {
  local need="$1" minfree="$CODER_GPU_MIN_FREE_MIB" maxutil="$CODER_GPU_MAX_UTIL_PCT"
  local exclude; exclude="$(reserved_gpus)"
  nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
    | awk -F',' -v minfree="$minfree" -v maxutil="$maxutil" -v excl="$exclude" '
        BEGIN { n = split(excl, ex, ","); for (i = 1; i <= n; i++) { gsub(/ /,"",ex[i]); skip[ex[i]] = 1 } }
        {
          gsub(/ /,"",$1); gsub(/ /,"",$2); gsub(/ /,"",$3); gsub(/ /,"",$4);
          if ($1 in skip) next;
          free = $3 - $2;
          if (free >= minfree && $4+0 <= maxutil) print free, $1;
        }' \
    | sort -rn -k1,1 \
    | awk -v need="$need" 'NR<=need{print $2}' \
    | paste -sd, -
}

cmd_start() {
  if is_coder_up; then
    log "already running (pid $(cat "$HPC_RUN/coder.pid")). See: coder status"
    return 0
  fi

  local want="${CODER_TP_SIZE:-4}"
  local picked
  if [[ -n "${CODER_GPUS:-}" ]]; then
    picked="$CODER_GPUS"
    log "using manually-set CODER_GPUS=$picked (skipping auto-pick)"
  else
    log "checking nvidia-smi for ${want} GPU(s) with >= ${CODER_GPU_MIN_FREE_MIB} MiB free and <= ${CODER_GPU_MAX_UTIL_PCT}% utilization..."
    picked="$(pick_free_gpus "$want")"
    local n=0; [[ -n "$picked" ]] && n=$(( $(grep -o ',' <<<"$picked" | wc -l) + 1 ))
    if (( n < want )); then
      err "only found $n free GPU(s), need $want. Not guessing further -"
      err "  run 'nvidia-smi' yourself; this is a shared box, it may just be busy right now."
      return 1
    fi
    log "picked GPUs: $picked"
  fi

  export CODER_GPUS="$picked"
  export CODER_MODEL="${CODER_MODEL:-Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8}"
  export CODER_TP_SIZE="$want"
  export CODER_SERVED_NAME="${CODER_SERVED_NAME:-qwen3-coder-480b}"
  export CODER_EXTRA_ARGS="${CODER_EXTRA_ARGS:---max-model-len 32768 --gpu-memory-utilization 0.90 --enable-auto-tool-choice --tool-call-parser qwen3_coder}"

  bash "$SELF_DIR/svc.sh" start coder || return 1

  log "waiting for model to load from disk (~450GB - this genuinely takes minutes)..."
  local waited=0
  until curl -fsS -m 3 "http://127.0.0.1:${CODER_PORT}/health" >/dev/null 2>&1; do
    if ! is_coder_up; then
      err "coder process died while loading - check: svc logs coder"
      return 1
    fi
    sleep 10; waited=$((waited + 10))
    if (( waited % 60 == 0 )); then
      log "  still loading... (${waited}s elapsed - svc logs coder for detail)"
    fi
    if (( waited >= 1200 )); then
      err "still not healthy after 20 minutes - something's likely wrong. Check: svc logs coder"
      return 1
    fi
  done
  log "ready. Endpoint: http://127.0.0.1:${CODER_PORT}/v1"
  log "  (or via litellm: http://127.0.0.1:${LITELLM_PORT}/v1, model=qwen3-coder-480b - what Continue uses)"

  bash "$SELF_DIR/svc.sh" stop coder-watch >/dev/null 2>&1 || true
  bash "$SELF_DIR/svc.sh" start coder-watch >/dev/null
  log "idle-watch armed: auto-stop after ${CODER_IDLE_TIMEOUT}s with no requests."
}

cmd_stop() {
  bash "$SELF_DIR/svc.sh" stop coder-watch
  bash "$SELF_DIR/svc.sh" stop coder
  log "stopped. GPUs released."
}

cmd_status() {
  if is_coder_up; then
    local pid gpus
    pid="$(cat "$HPC_RUN/coder.pid")"
    gpus="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^CODER_GPUS=' | cut -d= -f2)"
    log "coder: UP (pid $pid, GPUs ${gpus:-unknown})"
    if curl -fsS -m 3 "http://127.0.0.1:${CODER_PORT}/health" >/dev/null 2>&1; then
      log "  health: OK"
    else
      log "  health: not responding yet (still loading? check: svc logs coder)"
    fi
    if [[ -f "$HPC_RUN/coder-watch.pid" ]] && kill -0 "$(cat "$HPC_RUN/coder-watch.pid" 2>/dev/null)" 2>/dev/null; then
      log "  idle-watch: running, auto-stop after ${CODER_IDLE_TIMEOUT}s idle (svc logs coder-watch for detail)"
    else
      log "  idle-watch: NOT running - no auto-stop is active. Run 'coder stop' then 'coder start' to fix."
    fi
  else
    log "coder: DOWN. Run 'coder start' to bring it up (picks free GPUs automatically)."
  fi
}

case "${1:-status}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *) err "usage: coder-ctl.sh {start|status|stop}"; exit 1 ;;
esac
