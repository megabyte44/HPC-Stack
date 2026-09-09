#!/usr/bin/env bash
# =============================================================================
# doctor.sh - verifies nothing is leaking into $HOME and everything is wired up.
# Run this whenever something feels wrong, and after any new pip/npm install.
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/00-env.sh"

ok()   { printf '  \033[1;32mOK  \033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31mBAD \033[0m %s\n' "$*"; }
note() { printf '  \033[1;33m--  \033[0m %s\n' "$*"; }

echo; echo "  Node: $(hostname -s)   Project: $HPC_PROJECT"; echo

# --- quota -----------------------------------------------------------------
echo "QUOTA"
if command -v quota >/dev/null 2>&1; then quota -s 2>/dev/null | sed 's/^/  /'; else
  note "'quota' unavailable; using du"; fi
echo "  \$HOME size:   $(du -sh "$HOME" 2>/dev/null | cut -f1)"
echo "  \$HOME inodes: $(find "$HOME" -xdev 2>/dev/null | wc -l)"
echo

# --- the leak check: heavy hidden dirs that should NOT be in $HOME ---------
echo "HOME LEAK CHECK"
LEAKY=(.cache .local/share .ollama .npm .conda .cargo .nv .triton
       huggingface .n8n .config/Ollama miniconda3 anaconda3 .cloudflared)
found=0
for d in "${LEAKY[@]}"; do
  p="$HOME/$d"
  [[ -e "$p" ]] || continue
  sz=$(du -sm "$p" 2>/dev/null | cut -f1)
  if [[ "${sz:-0}" -ge 100 ]]; then
    bad "$d is ${sz} MB - a cache var is not being honoured"
    found=1
  elif [[ "${sz:-0}" -ge 10 ]]; then
    note "$d is ${sz} MB (watch it)"
  fi
done
[[ $found -eq 0 ]] && ok "no large caches in \$HOME"
echo

# --- env vars --------------------------------------------------------------
echo "ENVIRONMENT"
for v in HF_HOME PIP_CACHE_DIR UV_CACHE_DIR XDG_CACHE_HOME OLLAMA_MODELS \
         NPM_CONFIG_CACHE NPM_CONFIG_PREFIX N8N_USER_FOLDER TMPDIR TORCH_HOME; do
  val="${!v:-}"
  if [[ -z "$val" ]]; then bad "$v unset"
  elif [[ "$val" == "$HOME"* ]]; then bad "$v points into \$HOME: $val"
  else ok "$v -> $val"; fi
done
echo

# --- binaries --------------------------------------------------------------
echo "BINARIES"
for b in ollama node npm uv open-webui n8n litellm cloudflared moto_server; do
  if command -v "$b" >/dev/null 2>&1; then ok "$(printf '%-11s' "$b") $(command -v "$b")"
  else note "$(printf '%-11s' "$b") not installed"; fi
done
echo

# --- endpoints -------------------------------------------------------------
echo "ENDPOINTS"
probe() {
  if curl -fsS -m 4 "$2" >/dev/null 2>&1; then ok "$1 responding on $2"
  else note "$1 not responding on $2"; fi
}
probe ollama  "http://127.0.0.1:${OLLAMA_PORT}/api/tags"
probe webui   "http://127.0.0.1:${WEBUI_PORT}/health"
probe n8n     "http://127.0.0.1:${N8N_PORT}/healthz"
probe litellm "http://127.0.0.1:${LITELLM_PORT}/health/liveliness"
probe moto    "http://127.0.0.1:${MOTO_PORT}/"
echo

# --- exposure / auth ---------------------------------------------------------
echo "EXPOSURE"
if [[ -f "$CLOUDFLARE_TUNNEL_TOKEN_FILE" ]]; then
  note "cloudflared token present - some port may be reachable from the public internet, not just your SSH tunnel"
  if [[ "${ENABLE_SIGNUP:-true}" != "false" ]]; then
    bad "ENABLE_SIGNUP is not 'false' while a tunnel token exists - open-webui would let strangers self-register"
  else
    ok "open-webui ENABLE_SIGNUP=false"
  fi
  # N8N_BASIC_AUTH_ACTIVE is silently ignored by modern n8n - test the real
  # gate instead: an authenticated-only endpoint must 401 without a session.
  if curl -fsS -m 4 "http://127.0.0.1:${N8N_PORT}/rest/workflows" 2>/dev/null | grep -q '"data"'; then
    bad "n8n /rest/workflows served data with no session - an owner account may already be world-readable"
  else
    ok "n8n /rest/workflows rejects unauthenticated requests"
  fi
  if curl -fsS -m 4 "http://127.0.0.1:${N8N_PORT}/rest/settings" 2>/dev/null | grep -q '"showSetupOnFirstLoad":true'; then
    bad "n8n has NO owner account yet - whoever loads the UI next becomes owner. Sign up now, before routing a public hostname at this port."
  fi
else
  note "no cloudflared token file - stack is SSH-tunnel-only (default, safest)"
fi
echo

# --- models ----------------------------------------------------------------
if command -v ollama >/dev/null 2>&1 && curl -fsS -m 4 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1; then
  echo "MODELS"; ollama list 2>/dev/null | sed 's/^/  /'; echo
fi

# --- /tmp survival ---------------------------------------------------------
echo "SCRATCH"
if [[ -d "$WORK" ]]; then
  ok "\$WORK exists, $(du -sh "$WORK" 2>/dev/null | cut -f1) used"
  echo "  free on filesystem: $(df -h "$WORK" 2>/dev/null | awk 'NR==2{print $4}')"
else
  bad "\$WORK is GONE - /tmp was reaped. Re-run 10-toolchain.sh and 20-apps.sh"
fi
echo
