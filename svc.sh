#!/usr/bin/env bash
# =============================================================================
# svc.sh - tiny process supervisor. There is no systemd available to you, so
# services are launched with setsid+nohup so they survive your SSH logout,
# and tracked with pid files under $HPC_RUN.
#
#   svc.sh start   all|ollama|webui|n8n|litellm
#   svc.sh stop    all|<name>
#   svc.sh restart <name>
#   svc.sh status
#   svc.sh logs    <name>          # tail -f
#   svc.sh pull    llama3.1:8b     # download a model
#
# Can be invoked from the master node too - it will re-exec itself over ssh.
# =============================================================================
set -uo pipefail

source "$(dirname "$(readlink -f "$0")")/00-env.sh"

SERVICES=(ollama webui n8n litellm vllm vlm coder comfyui cloudflared moto keepalive)

c()   { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
err() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

# --- transparently hop to the GPU node if we are on the master -------------
if [[ "$(hostname -s)" != "$HPC_GPU_NODE" ]]; then
  warn "Not on $HPC_GPU_NODE - forwarding this command over ssh..."
  exec ssh -t "$HPC_GPU_NODE" "bash $HOME/hpc-stack/svc.sh $*"
fi

mkdir -p "$HPC_RUN" "$HPC_LOGS"

pidfile() { echo "$HPC_RUN/$1.pid"; }
logfile() { echo "$HPC_LOGS/$1.log"; }

is_up() {
  local pf; pf="$(pidfile "$1")"
  [[ -f "$pf" ]] || return 1
  local pid; pid="$(cat "$pf" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

port_of() {
  case "$1" in
    ollama)     echo "$OLLAMA_PORT" ;;
    webui)      echo "$WEBUI_PORT" ;;
    n8n)        echo "$N8N_PORT" ;;
    litellm)    echo "$LITELLM_PORT" ;;
    vllm)       echo "$VLLM_PORT" ;;
    vlm)        echo "$VLM_PORT" ;;
    coder)      echo "$CODER_PORT" ;;
    comfyui)    echo "$COMFYUI_PORT" ;;
    cloudflared) echo "" ;;   # outbound-only, nothing to bind locally
    moto)       echo "$MOTO_PORT" ;;
    keepalive)  echo "" ;;   # background loop, nothing to bind
  esac
}

# Launch $2.. detached, record pid, append to log.
spawn() {
  local name="$1"; shift
  local lf; lf="$(logfile "$name")"
  echo "--- started $(date -Is) ---" >> "$lf"
  setsid nohup "$@" >> "$lf" 2>&1 < /dev/null &
  local pid=$!
  echo "$pid" > "$(pidfile "$name")"
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    local p; p="$(port_of "$name")"; [[ -n "$p" ]] || p="-"
    c "  started $name (pid $pid, port $p)"
  else
    err "  $name died immediately. Last lines of $lf:"
    tail -n 20 "$lf" >&2
    return 1
  fi
}

start_one() {
  local name="$1"
  if is_up "$name"; then c "  $name already running (pid $(cat "$(pidfile "$name")"))"; return 0; fi

  # refuse to fight another user for the port (skip if this service has none)
  local p; p="$(port_of "$name")"
  if [[ -n "$p" ]] && command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":$p "; then
    err "  port $p is already taken. Set HPC_PORT_OFFSET and retry."
    return 1
  fi

  case "$name" in
    ollama)
      spawn ollama "$HPC_BIN/ollama" serve
      ;;
    webui)
      is_up ollama || warn "  (ollama is down; webui will show no models)"
      spawn webui "$HPC_BIN/open-webui" serve \
        --host 127.0.0.1 --port "$WEBUI_PORT"
      ;;
    n8n)
      spawn n8n "$NPM_CONFIG_PREFIX/bin/n8n" start
      ;;
    litellm)
      spawn litellm "$HPC_BIN/litellm" \
        --config "$HPC_APPS/litellm/config.yaml" \
        --host 127.0.0.1 --port "$LITELLM_PORT"
      ;;
    vllm)
      : "${VLLM_MODEL:?set VLLM_MODEL before: svc start vllm}"
      : "${VLLM_GPUS:?set VLLM_GPUS (e.g. 0,1,3,4) before: svc start vllm}"
      CUDA_VISIBLE_DEVICES="$VLLM_GPUS" spawn vllm "$HPC_BIN/vllm" serve "$VLLM_MODEL" \
        --port "$VLLM_PORT" \
        --served-model-name "${VLLM_SERVED_NAME:-$VLLM_MODEL}" \
        --tensor-parallel-size "${VLLM_TP_SIZE:-1}" \
        ${VLLM_EXTRA_ARGS:-}
      ;;
    vlm)
      : "${VLM_MODEL:?set VLM_MODEL before: svc start vlm}"
      : "${VLM_GPU:?set VLM_GPU (e.g. 4) before: svc start vlm}"
      CUDA_VISIBLE_DEVICES="$VLM_GPU" spawn vlm "$HPC_BIN/vllm" serve "$VLM_MODEL" \
        --port "$VLM_PORT" \
        --served-model-name "${VLM_SERVED_NAME:-$VLM_MODEL}" \
        --tensor-parallel-size "${VLM_TP_SIZE:-1}" \
        ${VLM_EXTRA_ARGS:-}
      ;;
    coder)
      : "${CODER_MODEL:?set CODER_MODEL before: svc start coder}"
      : "${CODER_GPUS:?set CODER_GPUS (e.g. 0,1,3,4) before: svc start coder}"
      CUDA_VISIBLE_DEVICES="$CODER_GPUS" spawn coder "$HPC_BIN/vllm" serve "$CODER_MODEL" \
        --port "$CODER_PORT" \
        --served-model-name "${CODER_SERVED_NAME:-$CODER_MODEL}" \
        --tensor-parallel-size "${CODER_TP_SIZE:-1}" \
        ${CODER_EXTRA_ARGS:-}
      ;;
    comfyui)
      : "${COMFYUI_GPU:?set COMFYUI_GPU (e.g. 5) before: svc start comfyui}"
      CUDA_VISIBLE_DEVICES="$COMFYUI_GPU" spawn comfyui "$HPC_APPS/comfyui/venv/bin/python" \
        "$HPC_APPS/comfyui/ComfyUI/main.py" \
        --listen 127.0.0.1 --port "$COMFYUI_PORT"
      ;;
    cloudflared)
      if [[ ! -f "$CLOUDFLARE_TUNNEL_TOKEN_FILE" ]]; then
        err "  No token at $CLOUDFLARE_TUNNEL_TOKEN_FILE."
        err "  echo '<token>' > $CLOUDFLARE_TUNNEL_TOKEN_FILE && chmod 600 $CLOUDFLARE_TUNNEL_TOKEN_FILE"
        return 1
      fi
      spawn cloudflared "$HPC_BIN/cloudflared" tunnel run \
        --token "$(cat "$CLOUDFLARE_TUNNEL_TOKEN_FILE")"
      ;;
    moto)
      spawn moto "$HPC_BIN/moto_server" -H "$MOTO_HOST" -p "$MOTO_PORT"
      ;;
    keepalive)
      spawn keepalive "$(dirname "$0")/keepalive.sh"
      ;;
    *) err "unknown service: $name"; return 1 ;;
  esac
}

stop_one() {
  local name="$1" pf pid
  pf="$(pidfile "$name")"
  if ! is_up "$name"; then c "  $name not running"; rm -f "$pf"; return 0; fi
  pid="$(cat "$pf")"
  # negative pid = whole process group, since we used setsid
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  for _ in $(seq 1 15); do is_up "$name" || break; sleep 1; done
  if is_up "$name"; then
    warn "  $name ignored SIGTERM; sending SIGKILL"
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  fi
  rm -f "$pf"
  c "  stopped $name"
}

cmd_status() {
  printf '\n  %-9s %-8s %-8s %s\n' SERVICE STATE PORT PID
  printf '  %s\n' "----------------------------------------------"
  for s in "${SERVICES[@]}"; do
    local p; p="$(port_of "$s")"; [[ -n "$p" ]] || p="-"
    if is_up "$s"; then
      printf '  \033[1;32m%-9s %-8s\033[0m %-8s %s\n' "$s" up "$p" "$(cat "$(pidfile "$s")")"
    else
      printf '  \033[1;30m%-9s %-8s %-8s -\033[0m\n' "$s" down "$p"
    fi
  done
  echo
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "  GPU:"
    nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total \
               --format=csv,noheader | sed 's/^/    /'
  fi
  echo "  Disk: \$WORK = $(du -sh "$WORK" 2>/dev/null | cut -f1), \$HOME = $(du -sh "$HOME" 2>/dev/null | cut -f1)"
  echo
}

ACTION="${1:-status}"; TARGET="${2:-all}"

case "$ACTION" in
  start)
    if [[ "$TARGET" == all ]]; then for s in "${SERVICES[@]}"; do start_one "$s"; done
    else start_one "$TARGET"; fi
    cmd_status ;;
  stop)
    if [[ "$TARGET" == all ]]; then for s in "${SERVICES[@]}"; do stop_one "$s"; done
    else stop_one "$TARGET"; fi ;;
  restart)
    if [[ "$TARGET" == all ]]; then
      for s in "${SERVICES[@]}"; do stop_one "$s"; done
      for s in "${SERVICES[@]}"; do start_one "$s"; done
    else stop_one "$TARGET"; start_one "$TARGET"; fi
    cmd_status ;;
  status)  cmd_status ;;
  logs)    tail -f "$(logfile "$TARGET")" ;;
  pull)
    is_up ollama || { err "ollama is down. svc.sh start ollama"; exit 1; }
    shift; "$HPC_BIN/ollama" pull "$@" ;;
  *)
    err "usage: svc.sh {start|stop|restart|status|logs|pull} [service]"; exit 1 ;;
esac
