#!/usr/bin/env bash
# =============================================================================
# 10-toolchain.sh - install ollama + node + uv onto the GPU node's local disk.
# No sudo, no package manager, no Docker. Idempotent: safe to re-run after
# /tmp has been reaped.
#
# RUN THIS ON dgx-node1, not on the master node.
# =============================================================================
set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/00-env.sh"

NODE_VERSION="${NODE_VERSION:-22.17.0}"   # any recent LTS

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

# --- guard: refuse to run on the wrong node --------------------------------
if [[ "$(hostname -s)" != "$HPC_GPU_NODE" ]]; then
  die "You are on '$(hostname -s)'. This must run on '$HPC_GPU_NODE'.
     Try:  ssh $HPC_GPU_NODE 'bash ~/hpc-stack/10-toolchain.sh'"
fi

log "Building tree under $WORK"
mkdir -p "$HPC_OPT" "$HPC_BIN" "$HPC_APPS" "$HPC_CACHE" "$HPC_MODELS" \
         "$HPC_LOGS" "$HPC_RUN" "$HPC_VENVS" "$TMPDIR" \
         "$OLLAMA_MODELS" "$HF_HUB_CACHE" "$NPM_CONFIG_PREFIX"
chmod 700 "$WORK"    # other cluster users share this /tmp

# --- sanity: is there actually a GPU here? ---------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
  log "GPUs visible:"
  nvidia-smi --query-gpu=index,name,memory.used,memory.total \
             --format=csv,noheader | sed 's/^/      /'
else
  log "WARNING: nvidia-smi not found. Ollama will fall back to CPU."
fi

# --- 1. ollama (static tarball; the official install.sh needs sudo) --------
if [[ -x "$HPC_BIN/ollama" ]]; then
  log "ollama already present: $("$HPC_BIN/ollama" --version 2>/dev/null | head -1)"
else
  log "Downloading ollama (linux-amd64 tarball)..."
  # As of ollama >=0.9 the release asset is zstd-compressed (.tar.zst), not
  # gzip (.tgz). GNU tar >=1.31 can pull the file straight through zstd.
  curl -fsSL --retry 3 \
    https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst \
    -o "$TMPDIR/ollama.tar.zst" || die "ollama download failed (proxy/firewall?)"
  # The tarball unpacks to bin/ and lib/ - keep them side by side.
  tar --zstd -xf "$TMPDIR/ollama.tar.zst" -C "$HPC_OPT"
  rm -f "$TMPDIR/ollama.tar.zst"
  [[ -x "$HPC_BIN/ollama" ]] || die "ollama binary not where expected"
  log "ollama installed: $("$HPC_BIN/ollama" --version 2>/dev/null | head -1)"
fi

# --- 2. node.js (prebuilt binary tarball) ---------------------------------
if [[ -x "$HPC_OPT/node/bin/node" ]]; then
  log "node already present: $("$HPC_OPT/node/bin/node" --version)"
else
  log "Downloading node v${NODE_VERSION}..."
  curl -fsSL --retry 3 \
    "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    -o "$TMPDIR/node.tar.xz" || die "node download failed"
  mkdir -p "$HPC_OPT/node"
  tar -xJf "$TMPDIR/node.tar.xz" -C "$HPC_OPT/node" --strip-components=1
  rm -f "$TMPDIR/node.tar.xz"
  log "node installed: $("$HPC_OPT/node/bin/node" --version)"
fi

# --- 3. uv (fast python installer; also manages CPython itself) -----------
if [[ -x "$HPC_BIN/uv" ]]; then
  log "uv already present: $("$HPC_BIN/uv" --version)"
else
  log "Downloading uv..."
  curl -LsSf --retry 3 https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR="$HPC_BIN" INSTALLER_NO_MODIFY_PATH=1 sh \
    || die "uv install failed"
  log "uv installed: $("$HPC_BIN/uv" --version)"
fi

# --- 4. a managed python, so we never touch the system one ---------------
log "Ensuring managed CPython 3.11..."
"$HPC_BIN/uv" python install 3.11 >/dev/null 2>&1 || true

log "Toolchain complete."
log "Disk used by \$WORK: $(du -sh "$WORK" 2>/dev/null | cut -f1)"
log "Next:  bash ~/hpc-stack/20-apps.sh"
