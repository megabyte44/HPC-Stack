#!/usr/bin/env bash
# =============================================================================
# 20-apps.sh - install open-webui, n8n and (optionally) litellm into /tmp.
# Run on dgx-node1 AFTER 10-toolchain.sh.
#
#   bash 20-apps.sh              # everything
#   bash 20-apps.sh webui n8n    # a subset
# =============================================================================
set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/00-env.sh"

log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(hostname -s)" == "$HPC_GPU_NODE" ]] || die "Run this on $HPC_GPU_NODE."
command -v uv >/dev/null   || die "uv not on PATH. Run 10-toolchain.sh first."
command -v npm >/dev/null  || die "npm not on PATH. Run 10-toolchain.sh first."

TARGETS=("$@"); [[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(webui n8n litellm)
want() { printf '%s\n' "${TARGETS[@]}" | grep -qx "$1"; }

mkdir -p "$HPC_APPS/open-webui" "$N8N_USER_FOLDER"

# --- open-webui ------------------------------------------------------------
# Pulls torch + sentence-transformers: expect ~4-6 GB. All of it under $WORK.
if want webui; then
  if [[ -x "$HPC_BIN/open-webui" ]]; then
    log "open-webui already installed."
  else
    log "Installing open-webui (large; several minutes)..."
    uv tool install open-webui --python 3.11 || die "open-webui install failed"
    log "open-webui installed."
  fi
  # A stable secret so sessions survive restarts.
  if [[ ! -f "$WEBUI_SECRET_KEY_FILE" ]]; then
    head -c 32 /dev/urandom | base64 > "$WEBUI_SECRET_KEY_FILE"
    chmod 600 "$WEBUI_SECRET_KEY_FILE"
  fi
fi

# --- n8n -------------------------------------------------------------------
if want n8n; then
  if [[ -x "$NPM_CONFIG_PREFIX/bin/n8n" ]]; then
    log "n8n already installed: $("$NPM_CONFIG_PREFIX/bin/n8n" --version 2>/dev/null || echo '?')"
  else
    log "Installing n8n via npm (prefix=$NPM_CONFIG_PREFIX)..."
    npm install -g n8n --no-fund --no-audit || die "n8n install failed"
    log "n8n installed."
  fi
  log "n8n has no auth of its own until you create the owner account -"
  log "  open http://127.0.0.1:${N8N_PORT} (through your SSH tunnel) and sign up"
  log "  NOW, before this port is ever reachable beyond your own SSH key."
fi

# --- litellm (optional API gateway: real API keys, budgets, one endpoint) ---
if want litellm; then
  if [[ -x "$HPC_BIN/litellm" ]]; then
    log "litellm already installed."
  else
    log "Installing litellm[proxy]..."
    uv tool install "litellm[proxy]" --python 3.11 || die "litellm install failed"
  fi
  CFG="$HPC_APPS/litellm/config.yaml"
  MASTER_KEY_FILE="$HOME/hpc-stack/.litellm_master_key"
  if [[ -f "$MASTER_KEY_FILE" ]]; then
    MASTER_KEY="$(cat "$MASTER_KEY_FILE")"
  else
    MASTER_KEY="sk-$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"
    echo "$MASTER_KEY" > "$MASTER_KEY_FILE"
    chmod 600 "$MASTER_KEY_FILE"
  fi
  if [[ ! -f "$CFG" ]]; then
    mkdir -p "$HPC_APPS/litellm"
    cat > "$CFG" <<YAML
model_list:
  - model_name: local-chat
    litellm_params:
      model: ollama_chat/llama3.2:3b
      api_base: http://127.0.0.1:${OLLAMA_PORT}
  - model_name: local-code
    litellm_params:
      model: ollama_chat/qwen2.5-coder:7b
      api_base: http://127.0.0.1:${OLLAMA_PORT}
  - model_name: qwen3-235b
    litellm_params:
      model: hosted_vllm/qwen3-235b
      api_base: http://127.0.0.1:${VLLM_PORT}/v1
  - model_name: qwen3-coder-480b
    litellm_params:
      model: hosted_vllm/qwen3-coder-480b
      api_base: http://127.0.0.1:${CODER_PORT}/v1
general_settings:
  master_key: ${MASTER_KEY}
YAML
    log "Wrote $CFG (master key reused from $MASTER_KEY_FILE)."
  fi
fi

# --- cloudflared (optional: public tunnel, opt-in only) ---------------------
# Raw static binary, no package manager. Only fetched if you explicitly ask
# for it: `bash 20-apps.sh cloudflared`. See the security note in 00-env.sh
# before routing any hostname at it - it can expose a port to the entire
# internet, not just people with your SSH key.
if want cloudflared; then
  if [[ -x "$HPC_BIN/cloudflared" ]]; then
    log "cloudflared already installed: $("$HPC_BIN/cloudflared" --version 2>/dev/null | head -1)"
  else
    log "Downloading cloudflared..."
    curl -fsSL --retry 3 \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o "$HPC_BIN/cloudflared" || die "cloudflared download failed"
    chmod +x "$HPC_BIN/cloudflared"
    log "cloudflared installed: $("$HPC_BIN/cloudflared" --version 2>/dev/null | head -1)"
  fi
  if [[ ! -f "$CLOUDFLARE_TUNNEL_TOKEN_FILE" ]]; then
    log "No token yet at $CLOUDFLARE_TUNNEL_TOKEN_FILE."
    log "  Create it yourself: echo '<your-tunnel-token>' > $CLOUDFLARE_TUNNEL_TOKEN_FILE && chmod 600 $CLOUDFLARE_TUNNEL_TOKEN_FILE"
    log "  Then in the Cloudflare dashboard, add Public Hostname routes pointing"
    log "  at http://127.0.0.1:<port> for whichever services you want public."
    log "  Do NOT route a hostname straight at ollama ($OLLAMA_PORT) - it has no"
    log "  auth of its own. Route litellm ($LITELLM_PORT) instead if you need"
    log "  model access from outside, since it requires its master_key."
  fi
fi

# --- moto (optional: LocalStack-style AWS emulator, no Docker needed) ------
if want moto; then
  if [[ -x "$HPC_BIN/moto_server" ]]; then
    log "moto already installed: $("$HPC_BIN/moto_server" --version 2>/dev/null || echo '?')"
  else
    log "Installing moto[server] (broad AWS API coverage)..."
    uv tool install "moto[server]" --python 3.11 || die "moto install failed"
    log "moto installed."
  fi
fi

log "Apps ready. \$WORK now uses $(du -sh "$WORK" 2>/dev/null | cut -f1)"
log "Home dir usage (should stay tiny): $(du -sh "$HOME" 2>/dev/null | cut -f1)"
log "Next:  bash ~/hpc-stack/svc.sh start all"
