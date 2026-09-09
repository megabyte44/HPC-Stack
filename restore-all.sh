#!/usr/bin/env bash
# =============================================================================
# restore-all.sh - full disaster recovery after $WORK gets wiped (e.g. a
# dgx-node1 reboot - $WORK lives on node-local /tmp, so it does NOT survive
# one). Everything under ~/hpc-stack (this script included) lives on NFS
# $HOME and always survives, so this is the ONE thing you need to remember.
#
# Usage (from the master node or dgx-node1, doesn't matter which):
#   bash ~/hpc-stack/restore-all.sh            # base stack only
#   bash ~/hpc-stack/restore-all.sh --models   # base stack + the 2 LLMs
#
# What it restores:
#   - toolchain (uv, ollama, node) + apps (open-webui, n8n, litellm, moto,
#     cloudflared) via 10-toolchain.sh / 20-apps.sh
#   - base services started (ollama, webui, n8n, litellm, moto, cloudflared,
#     keepalive)
#   - the 2 Ollama fallback models (llama3.2:3b, qwen2.5-coder:7b)
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

log "4/5 pulling Ollama fallback models..."
~/hpc-stack/svc.sh pull llama3.2:3b
~/hpc-stack/svc.sh pull qwen2.5-coder:7b

if [[ "${1:-}" != "--models" ]]; then
  log "Base stack restored. Re-run with --models to also bring back the two vLLM models."
  ~/hpc-stack/svc.sh status
  exit 0
fi

log "5/5 installing vLLM + starting the two models (this downloads ~717GB total, will take a while)..."
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
export CODER_GPUS="${CODER_GPUS:-4,5,6,7}"
export CODER_TP_SIZE="${CODER_TP_SIZE:-4}"
export CODER_SERVED_NAME="${CODER_SERVED_NAME:-qwen3-coder-480b}"
export CODER_EXTRA_ARGS="${CODER_EXTRA_ARGS:---max-model-len 32768 --gpu-memory-utilization 0.90 --enable-auto-tool-choice --tool-call-parser qwen3_coder}"
~/hpc-stack/svc.sh start coder

log "Launched. Both models download+load in the background - watch with:"
log "  ~/hpc-stack/svc.sh logs vllm"
log "  ~/hpc-stack/svc.sh logs coder"
~/hpc-stack/svc.sh status
