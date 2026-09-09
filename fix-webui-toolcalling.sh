#!/usr/bin/env bash
# =============================================================================
# fix-webui-toolcalling.sh - reapplies the "legacy function_calling" override
# (KNOWLEDGE.md §5.4) for models that don't do real structured tool-calling
# (qwen2.5-coder:7b, llama3.2:3b via Ollama). Needed after every webui.db
# rebuild, because the `model` table starts empty and Open-WebUI won't let
# you set this from the UI for models it hasn't seen yet.
#
# Safe to run any time - it is a no-op (with a clear message) if webui.db
# doesn't exist yet, or if no user has signed up yet. Re-run it any time
# after signing in to Open-WebUI following a $WORK wipe.
#
#   bash ~/hpc-stack/fix-webui-toolcalling.sh
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/00-env.sh"

log() { printf '\033[1;36m[webui-fix]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[webui-fix]\033[0m %s\n' "$*" >&2; }

[[ "$(hostname -s)" == "$HPC_GPU_NODE" ]] || { exec ssh -t "$HPC_GPU_NODE" "bash \$HOME/hpc-stack/fix-webui-toolcalling.sh $*"; }

DB="$DATA_DIR/webui.db"
MODELS=(qwen2.5-coder:7b llama3.2:3b)

if [[ ! -f "$DB" ]]; then
  log "no webui.db yet at $DB - nothing to fix. Start webui and sign up first."
  exit 0
fi

USER_COUNT="$(python3 - "$DB" <<'PY' 2>/dev/null || echo 0
import sqlite3, sys
try:
    db = sqlite3.connect(sys.argv[1])
    print(db.execute("SELECT COUNT(*) FROM user").fetchone()[0])
except Exception:
    print(0)
PY
)"

if [[ -z "${USER_COUNT:-}" || "$USER_COUNT" == "0" ]]; then
  log "webui.db exists but has no user yet - sign up at http://127.0.0.1:${WEBUI_PORT} first,"
  log "  then re-run this script: bash ~/hpc-stack/fix-webui-toolcalling.sh"
  exit 0
fi

WAS_UP=0
if [[ -f "$HPC_RUN/webui.pid" ]] && kill -0 "$(cat "$HPC_RUN/webui.pid")" 2>/dev/null; then
  WAS_UP=1
  log "stopping webui to edit its sqlite db safely..."
  "$(dirname "$0")/svc.sh" stop webui
fi

log "applying legacy function_calling override for: ${MODELS[*]}"
python3 - "$DB" "${MODELS[@]}" <<'PY'
import sqlite3, json, time, sys

db_path, *models = sys.argv[1:]
db = sqlite3.connect(db_path)
cur = db.cursor()
row = cur.execute("SELECT id FROM user ORDER BY created_at ASC LIMIT 1").fetchone()
if not row:
    print("no user row found - skipping")
    sys.exit(0)
user_id = row[0]
now = int(time.time())
for model_id in models:
    cur.execute(
        """INSERT OR REPLACE INTO model
           (id, user_id, base_model_id, name, params, meta, updated_at, created_at, is_active)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)""",
        (model_id, user_id, model_id, model_id,
         json.dumps({"function_calling": "legacy"}),
         json.dumps({"capabilities": {"vision": False}}),
         now, now),
    )
db.commit()
print(f"applied to {len(models)} model(s) as user {user_id}")
PY

if [[ "$WAS_UP" -eq 1 ]]; then
  log "restarting webui..."
  "$(dirname "$0")/svc.sh" start webui
fi

log "done."
