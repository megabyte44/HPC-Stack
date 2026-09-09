#!/usr/bin/env bash
# =============================================================================
# 00-env.sh - single source of truth for the /tmp-backed GPU stack.
#
# Sourced by:  ~/.bashrc (interactive shells) AND explicitly by every script
#              in this bundle (because .bashrc exits early for non-interactive
#              ssh commands like:  ssh dgx-node1 'some-command').
#
# This file only DEFINES paths. It creates nothing except TMPDIR.
# Safe to source on the master node, on the compute node, anywhere.
# =============================================================================

# ---- identity -------------------------------------------------------------
: "${HPC_PROJECT:=hackathon01_work}"   # override to run a second stack
: "${HPC_GPU_NODE:=dgx-node1}"         # the node that actually runs things

export HPC_PROJECT HPC_GPU_NODE
export WORK="/tmp/${HPC_PROJECT}"

# ---- directory layout on the node's local disk ----------------------------
export HPC_OPT="$WORK/opt"        # toolchains: ollama, node, uv, python
export HPC_BIN="$HPC_OPT/bin"     # everything executable lands here
export HPC_APPS="$WORK/apps"      # app state: n8n db, open-webui db
export HPC_CACHE="$WORK/cache"    # every cache that would otherwise hit $HOME
export HPC_MODELS="$WORK/models"  # ollama blobs, HF weights
export HPC_LOGS="$WORK/logs"
export HPC_RUN="$WORK/run"        # pid files
export HPC_VENVS="$WORK/venvs"

# ---- generic scratch + XDG ------------------------------------------------
# XDG_* is the big one: it catches dozens of tools that would otherwise
# write to ~/.cache, ~/.local/share and ~/.config without telling you.
export XDG_CACHE_HOME="$HPC_CACHE/xdg"
export XDG_DATA_HOME="$WORK/share"
export XDG_STATE_HOME="$WORK/state"
export XDG_CONFIG_HOME="$WORK/config"

# TMPDIR must exist or half of coreutils/pip breaks. Fall back gracefully
# when we are on a node where $WORK has not been built yet (e.g. the master).
if mkdir -p "$WORK/tmp" 2>/dev/null; then
  export TMPDIR="$WORK/tmp"
else
  export TMPDIR="/tmp"
fi

# ---- python / pip / uv ----------------------------------------------------
export PIP_CACHE_DIR="$HPC_CACHE/pip"
export PYTHONPYCACHEPREFIX="$HPC_CACHE/pycache"
export UV_CACHE_DIR="$HPC_CACHE/uv"
export UV_PYTHON_INSTALL_DIR="$HPC_OPT/uv-python"   # uv-managed CPython
export UV_TOOL_DIR="$HPC_OPT/uv-tools"              # uv tool install targets
export UV_TOOL_BIN_DIR="$HPC_BIN"
export UV_INSTALL_DIR="$HPC_BIN"

# ---- ML model caches (these are the multi-GB offenders) -------------------
export HF_HOME="$HPC_MODELS/huggingface"
export HF_HUB_CACHE="$HF_HOME/hub"
export HF_TOKEN_FILE="$HOME/hpc-stack/.hf_token"
if [[ -f "$HF_TOKEN_FILE" ]]; then
  export HF_TOKEN="$(cat "$HF_TOKEN_FILE")"
fi
export HF_DATASETS_CACHE="$HF_HOME/datasets"
export HUGGINGFACE_HUB_CACHE="$HF_HUB_CACHE"
export SENTENCE_TRANSFORMERS_HOME="$HPC_MODELS/sentence-transformers"
export TORCH_HOME="$HPC_MODELS/torch"
export TRITON_CACHE_DIR="$HPC_CACHE/triton"
export CUDA_CACHE_PATH="$HPC_CACHE/nv"          # kills ~/.nv/ComputeCache
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export MPLCONFIGDIR="$HPC_CACHE/matplotlib"
export NUMBA_CACHE_DIR="$HPC_CACHE/numba"
export VLLM_CACHE_ROOT="$HPC_CACHE/vllm"
export TIKTOKEN_CACHE_DIR="$HPC_CACHE/tiktoken"

# ---- node / npm / n8n -----------------------------------------------------
export NPM_CONFIG_CACHE="$HPC_CACHE/npm"
export NPM_CONFIG_PREFIX="$HPC_OPT/node-global"
export NPM_CONFIG_UPDATE_NOTIFIER=false
export N8N_USER_FOLDER="$HPC_APPS/n8n"           # holds .n8n/database.sqlite

# ---- ports (all bound to loopback; bump HPC_PORT_OFFSET on a clash) -------
: "${HPC_PORT_OFFSET:=0}"
export OLLAMA_PORT=$((11434 + HPC_PORT_OFFSET))
export WEBUI_PORT=$((8080  + HPC_PORT_OFFSET))
export N8N_PORT=$((5678    + HPC_PORT_OFFSET))
export LITELLM_PORT=$((4000 + HPC_PORT_OFFSET))
export JUPYTER_PORT=$((8888 + HPC_PORT_OFFSET))
export MOTO_PORT=$((5000   + HPC_PORT_OFFSET))
export VLLM_PORT=$((8000  + HPC_PORT_OFFSET))
export VLM_PORT=$((8500  + HPC_PORT_OFFSET))
export COMFYUI_PORT=$((8188  + HPC_PORT_OFFSET))
export CODER_PORT=$((8700  + HPC_PORT_OFFSET))

# ---- ollama ---------------------------------------------------------------
export OLLAMA_MODELS="$HPC_MODELS/ollama"
export OLLAMA_HOST="127.0.0.1:${OLLAMA_PORT}"
export OLLAMA_KEEP_ALIVE="30m"      # keep weights resident between requests
export OLLAMA_NUM_PARALLEL=2
export OLLAMA_MAX_LOADED_MODELS=2
export OLLAMA_FLASH_ATTENTION=1

# ---- open-webui -----------------------------------------------------------
export DATA_DIR="$HPC_APPS/open-webui"
export OLLAMA_BASE_URL="http://127.0.0.1:${OLLAMA_PORT}"
export WEBUI_SECRET_KEY_FILE="$HPC_APPS/open-webui/.secret"
# The FIRST account created is always allowed to become admin regardless of
# this flag - it only blocks everyone *after* that. Kept off by default since
# these ports may end up reachable beyond the SSH tunnel (e.g. a Cloudflare
# tunnel) and open-webui has no other gate against strangers self-registering.
export ENABLE_SIGNUP=false
# Auto-wire webui to litellm so qwen3-235b/qwen3-coder-480b (vLLM, not
# Ollama) show up in the model picker without manually adding a Connection
# in the Admin UI every time webui.db gets rebuilt - Ollama models come in
# for free via OLLAMA_BASE_URL above, this is the same idea for everything
# behind litellm. No-op (webui just won't list them) until litellm has been
# installed at least once, i.e. its master key file exists.
export ENABLE_OPENAI_API=true
export OPENAI_API_BASE_URLS="http://127.0.0.1:${LITELLM_PORT}/v1"
LITELLM_MASTER_KEY_FILE="$HOME/hpc-stack/.litellm_master_key"
if [[ -f "$LITELLM_MASTER_KEY_FILE" ]]; then
  export OPENAI_API_KEYS="$(cat "$LITELLM_MASTER_KEY_FILE")"
fi

# ---- n8n runtime ----------------------------------------------------------
export N8N_HOST=127.0.0.1
export N8N_LISTEN_ADDRESS=127.0.0.1
export N8N_PROTOCOL=http
export WEBHOOK_URL="http://localhost:${N8N_PORT}/"
export N8N_SECURE_COOKIE=false                  # required over plain-http tunnel
export N8N_DIAGNOSTICS_ENABLED=false
export N8N_RUNNERS_ENABLED=true
export GENERIC_TIMEZONE="Asia/Kolkata"
# n8n's N8N_BASIC_AUTH_ACTIVE env var was removed upstream (still accepted,
# silently ignored as of n8n 2.x) - do NOT rely on it, it does nothing.
# n8n's real protection is its own owner-account gate: /rest/settings always
# reports showSetupOnFirstLoad, and every /rest/* endpoint 401s until an
# owner account exists. That gate has one weak point: whoever loads the UI
# FIRST gets to create the owner account. If you plan to put n8n behind a
# public Cloudflare hostname, create your owner account (open the n8n URL,
# fill in the signup form) BEFORE adding that Public Hostname route, and put
# a Cloudflare Access policy in front of the hostname for a real second
# factor - it authenticates the visitor before they ever reach n8n at all.

# ---- cloudflared (optional public tunnel) ----------------------------------
# We deliberately do NOT bind anything to 0.0.0.0 for this. cloudflared makes
# an OUTBOUND connection from this node to Cloudflare's edge and proxies a
# public hostname to a local 127.0.0.1:PORT you choose in the Cloudflare
# dashboard per named tunnel - so the token below controls what becomes
# reachable from the entire internet, not just people with your SSH key.
# Put your tunnel token in this file yourself (chmod 600) - never pass it
# through a script argument or commit it anywhere.
export CLOUDFLARE_TUNNEL_TOKEN_FILE="$HOME/hpc-stack/.cloudflare_tunnel_token"

# ---- moto (LocalStack-style AWS emulator, no Docker needed) ---------------
export MOTO_HOST=127.0.0.1

# ---- keepalive --------------------------------------------------------------
# /tmp reapers delete files untouched for N days - this just keeps mtimes
# fresh under $WORK so an idle stretch doesn't get it swept. Does NOT protect
# against a node reboot (that's what backup.sh + $HOME secrets are for).
: "${HPC_KEEPALIVE_INTERVAL:=21600}"   # seconds between touch sweeps (6h)
export HPC_KEEPALIVE_INTERVAL

# ---- PATH -----------------------------------------------------------------
_hpc_path_add() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac; }
_hpc_path_add "$NPM_CONFIG_PREFIX/bin"
_hpc_path_add "$HPC_OPT/node/bin"
_hpc_path_add "$HPC_BIN"
export PATH
unset -f _hpc_path_add
