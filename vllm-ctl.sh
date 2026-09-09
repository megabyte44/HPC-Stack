#!/usr/bin/env bash
# =============================================================================
# vllm-ctl.sh - start/status/stop for qwen3-235b, the always-on
# general-purpose model. Unlike coder-ctl.sh, this deliberately has NO
# idle-timeout - it stays up until you stop it yourself. What it gives you
# over raw `svc.sh start vllm` is the same convenience coder-ctl.sh gives
# for coder: a fresh nvidia-smi free-GPU pick instead of a hardcoded
# CODER_GPUS-style default that goes stale, and a wait-for-ready poll.
#
#   general start    # picks free GPUs fresh, launches vLLM, waits for ready
#   general status    # up/down, which GPUs, health
#   general stop      # stops it, releases the GPUs - your call, any time
#
# (bashrc-snippet.sh aliases 'general' to this script - NOT 'vllm', that
# name is already the real vLLM CLI binary in $PATH)
#
# Same no-Slurm situation as coder - see KNOWLEDGE.md §4a. GPU picking here
# is the same fresh nvidia-smi check, not scheduler-enforced isolation.
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/00-env.sh"

log() { printf '\033[1;34m[general]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[general]\033[0m %s\n' "$*" >&2; }

[[ "$(hostname -s)" == "$HPC_GPU_NODE" ]] || exec ssh -t "$HPC_GPU_NODE" "bash \$HOME/hpc-stack/vllm-ctl.sh $*"

SELF_DIR="$(dirname "$(readlink -f "$0")")"

is_vllm_up() {
  [[ -f "$HPC_RUN/vllm.pid" ]] && kill -0 "$(cat "$HPC_RUN/vllm.pid" 2>/dev/null)" 2>/dev/null
}

# GPUs dedicated to another always-on service - see the matching comment
# in coder-ctl.sh / KNOWLEDGE.md §4a.3 for why this exists.
reserved_gpus() {
  local out=""
  if [[ -f "$HPC_RUN/comfyui.pid" ]] && kill -0 "$(cat "$HPC_RUN/comfyui.pid" 2>/dev/null)" 2>/dev/null; then
    out="$(tr '\0' '\n' < "/proc/$(cat "$HPC_RUN/comfyui.pid")/environ" 2>/dev/null | grep '^CUDA_VISIBLE_DEVICES=' | cut -d= -f2)"
  fi
  echo "$out"
}

# Picks N GPUs by real headroom, not a flat "touched at all" threshold -
# see the matching comment in coder-ctl.sh / KNOWLEDGE.md §4a.3 for why.
pick_free_gpus() {
  local need="$1" minfree="$VLLM_GPU_MIN_FREE_MIB" maxutil="$VLLM_GPU_MAX_UTIL_PCT"
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
  if is_vllm_up; then
    log "already running (pid $(cat "$HPC_RUN/vllm.pid")). See: general status"
    return 0
  fi

  local want="${VLLM_TP_SIZE:-2}"
  local picked
  if [[ -n "${VLLM_GPUS:-}" ]]; then
    picked="$VLLM_GPUS"
    log "using manually-set VLLM_GPUS=$picked (skipping auto-pick)"
  else
    log "checking nvidia-smi for ${want} GPU(s) with >= ${VLLM_GPU_MIN_FREE_MIB} MiB free and <= ${VLLM_GPU_MAX_UTIL_PCT}% utilization..."
    picked="$(pick_free_gpus "$want")"
    local n=0; [[ -n "$picked" ]] && n=$(( $(grep -o ',' <<<"$picked" | wc -l) + 1 ))
    if (( n < want )); then
      err "only found $n free GPU(s), need $want. Not guessing further -"
      err "  run 'nvidia-smi' yourself; this is a shared box, it may just be busy right now."
      return 1
    fi
    log "picked GPUs: $picked"
  fi

  export VLLM_GPUS="$picked"
  export VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen3-235B-A22B-Instruct-2507-FP8}"
  export VLLM_TP_SIZE="$want"
  export VLLM_SERVED_NAME="${VLLM_SERVED_NAME:-qwen3-235b}"
  # 24576/0.85, not 32768/0.92 - the higher combo OOM'd twice in a row on
  # this shared box even with 137GB free at pick time (KNOWLEDGE.md §4a.3);
  # this lower combo is what actually came up clean.
  export VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:---max-model-len 24576 --gpu-memory-utilization 0.85 --enable-auto-tool-choice --tool-call-parser qwen3_xml}"

  bash "$SELF_DIR/svc.sh" start vllm || return 1

  log "waiting for model to load from disk (~235GB FP8 - this takes real minutes)..."
  local waited=0
  until curl -fsS -m 3 "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null 2>&1; do
    if ! is_vllm_up; then
      err "vllm process died while loading - check: svc logs vllm"
      return 1
    fi
    sleep 10; waited=$((waited + 10))
    if (( waited % 60 == 0 )); then
      log "  still loading... (${waited}s elapsed - svc logs vllm for detail)"
    fi
    if (( waited >= 1200 )); then
      err "still not healthy after 20 minutes - something's likely wrong. Check: svc logs vllm"
      return 1
    fi
  done
  log "ready. Endpoint: http://127.0.0.1:${VLLM_PORT}/v1"
  log "  (or via litellm: http://127.0.0.1:${LITELLM_PORT}/v1, model=qwen3-235b)"
  log "no idle-timeout on this one, by design - stop it yourself with 'general stop' when you want the GPUs back."
}

cmd_stop() {
  bash "$SELF_DIR/svc.sh" stop vllm
  log "stopped. GPUs released."
}

cmd_status() {
  if is_vllm_up; then
    local pid gpus
    pid="$(cat "$HPC_RUN/vllm.pid")"
    gpus="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^VLLM_GPUS=' | cut -d= -f2)"
    log "vllm (qwen3-235b): UP (pid $pid, GPUs ${gpus:-unknown})"
    if curl -fsS -m 3 "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null 2>&1; then
      log "  health: OK"
    else
      log "  health: not responding yet (still loading? check: svc logs vllm)"
    fi
    log "  idle-timeout: none by design - stops only when you run 'general stop'"
  else
    log "vllm (qwen3-235b): DOWN. Run 'general start' to bring it up (picks free GPUs automatically)."
  fi
}

case "${1:-status}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *) err "usage: vllm-ctl.sh {start|status|stop}"; exit 1 ;;
esac
