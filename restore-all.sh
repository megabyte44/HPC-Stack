#!/usr/bin/env bash
# =============================================================================
# restore-all.sh - full disaster recovery after $WORK gets wiped (e.g. a
# dgx-node1 reboot - $WORK lives on node-local /tmp, so it does NOT survive
# one). Everything under ~/hpc-stack (this script included) lives on NFS
# $HOME and always survives, so this is the ONE thing you need to remember.
#
# Usage (from the master node or dgx-node1, doesn't matter which):
#   bash ~/hpc-stack/restore-all.sh              # base stack only
#   bash ~/hpc-stack/restore-all.sh --models     # base stack + the 2 vLLM LLMs
#   bash ~/hpc-stack/restore-all.sh --comfyui    # base stack + ComfyUI
#   bash ~/hpc-stack/restore-all.sh --models --comfyui   # everything
#
# What it restores:
#   - toolchain (uv, ollama, node) + apps (open-webui, n8n, litellm, moto,
#     cloudflared) via 10-toolchain.sh / 20-apps.sh
#   - base services started (ollama, webui, n8n, litellm, moto, cloudflared,
#     keepalive)
#   - the 2 Ollama fallback models (llama3.2:3b, qwen2.5-coder:7b)
#   - the Open-WebUI tool-calling override (§5.4), if you've signed up already
#     (no-op otherwise - re-run fix-webui-toolcalling.sh after you do)
#   - with --comfyui: ComfyUI cloned + its venv built (you still start it
#     yourself once you've picked a free GPU - see the printed instructions)
#   - with --models: vLLM installed + qwen3-235b and qwen3-coder-480b started
#     (this re-downloads ~235GB + ~482GB of weights - only pass --models when
#     you actually want that to happen right now)
#
# GPU picks below are DEFAULTS from the last known-good run. This is a shared
# box - check `nvidia-smi` first and override VLLM_GPUS/CODER_GPUS (export
# before running this script) if those GPUs are no longer free.
# =============================================================================
set -uo pipefail
export HPC_PORT_OFFSET="${HPC_PORT_OFFSET:-100}"
source "$(dirname "$(readlink -f "$0")")/00-env.sh"

log() { printf '\033[1;35m[restore]\033[0m %s\n' "$*"; }

[[ "$(hostname -s)" == "$HPC_GPU_NODE" ]] || { echo "Run on $HPC_GPU_NODE (svc.sh hops automatically, this script does not)."; exec ssh -t "$HPC_GPU_NODE" "bash \$HOME/hpc-stack/restore-all.sh $*"; }

log "1/5 toolchain..."
bash ~/hpc-stack/10-toolchain.sh

log "2/5 apps (webui, n8n, litellm, moto, cloudflared)..."
bash ~/hpc-stack/20-apps.sh webui n8n litellm moto cloudflared

log "3/5 starting base services..."
for s in ollama webui n8n litellm moto cloudflared keepalive; do
  ~/hpc-stack/svc.sh start "$s"
done

log "4/6 pulling Ollama fallback models..."
~/hpc-stack/svc.sh pull llama3.2:3b
~/hpc-stack/svc.sh pull qwen2.5-coder:7b

log "5/6 re-applying Open-WebUI tool-calling override (§5.4)..."
log "  (no-op until you've signed up at http://127.0.0.1:${WEBUI_PORT} at least once -"
log "   re-run 'bash ~/hpc-stack/fix-webui-toolcalling.sh' after signing up if it skips)"
bash ~/hpc-stack/fix-webui-toolcalling.sh || true

if [[ " $* " == *" --comfyui "* ]]; then
  log "installing ComfyUI (§4, ~15-20 min, torch install is the slow part)..."
  if [[ ! -d "$HPC_APPS/comfyui/ComfyUI" ]]; then
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$HPC_APPS/comfyui/ComfyUI"
  fi
  if [[ ! -x "$HPC_APPS/comfyui/venv/bin/python" ]]; then
    uv venv --python 3.11 "$HPC_APPS/comfyui/venv"
    uv pip install --python "$HPC_APPS/comfyui/venv/bin/python" \
      --torch-backend cu128 torch torchvision torchaudio
    uv pip install --python "$HPC_APPS/comfyui/venv/bin/python" \
      -r "$HPC_APPS/comfyui/ComfyUI/requirements.txt"
  fi
  log "ComfyUI installed. Pick a free GPU (nvidia-smi) and start it yourself:"
  log "  export COMFYUI_GPU=<n>; ~/hpc-stack/svc.sh start comfyui"
fi

if [[ "${1:-}" != "--models" ]]; then
  log "Base stack restored. Re-run with --models to also bring back the two vLLM models"
  log "  (add --comfyui too if you also want that reinstalled)."
  ~/hpc-stack/svc.sh status
  exit 0
fi

log "6/6 installing vLLM + starting the two models (this downloads ~717GB total, will take a while)..."
if [[ ! -x "$HPC_OPT/uv-tools/vllm/bin/vllm" ]]; then
  uv tool install vllm==0.11.0 --python 3.11
  uv pip install --python "$HPC_OPT/uv-tools/vllm/bin/python3" transformers==4.57.6
fi

export VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen3-235B-A22B-Instruct-2507-FP8}"
export VLLM_GPUS="${VLLM_GPUS:-0,3}"
export VLLM_TP_SIZE="${VLLM_TP_SIZE:-2}"
export VLLM_SERVED_NAME="${VLLM_SERVED_NAME:-qwen3-235b}"
export VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:---max-model-len 32768 --gpu-memory-utilization 0.92 --enable-auto-tool-choice --tool-call-parser qwen3_xml}"
~/hpc-stack/svc.sh start vllm

# vLLM auto-picks a port for its internal multi-GPU rendezvous. Starting both
# engines back-to-back races them onto the same port (EADDRINUSE / gloo
# "connection closed by peer" - looks like an OOM or model bug, isn't one).
# Give the first one time to clear its own port-binding stage before the
# second starts.
sleep 30

export CODER_MODEL="${CODER_MODEL:-Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8}"
export CODER_TP_SIZE="${CODER_TP_SIZE:-4}"
export CODER_SERVED_NAME="${CODER_SERVED_NAME:-qwen3-coder-480b}"
export CODER_EXTRA_ARGS="${CODER_EXTRA_ARGS:---max-model-len 32768 --gpu-memory-utilization 0.90 --enable-auto-tool-choice --tool-call-parser qwen3_coder}"
# coder-ctl.sh picks free GPUs fresh via nvidia-smi and arms the idle-timeout
# watcher - do NOT hardcode CODER_GPUS here, it goes stale (see KNOWLEDGE.md
# §4a - this exact drift happened once already).
~/hpc-stack/coder-ctl.sh start

log "Launched. Both models download+load in the background - watch with:"
log "  ~/hpc-stack/svc.sh logs vllm"
log "  ~/hpc-stack/svc.sh logs coder"
~/hpc-stack/svc.sh status
