#!/usr/bin/env bash
# =============================================================================
# fix-webui-toolcalling.sh - two related webui.db fixes needed after every
# rebuild, because Open-WebUI won't let you configure either of these from
# the UI for a model it hasn't formally registered yet:
#
# 1. Legacy function-calling override (KNOWLEDGE.md §5.4) for models that
#    don't do real structured tool-calling (qwen2.5-coder:7b, llama3.2:3b
#    via Ollama; qwen3-235b via vLLM - buggy qwen3_xml parser).
# 2. Publishes each model to the workspace with a public read grant, so
#    non-admin accounts can see it at all. Confirmed 2026-09-09 by reading
#    open_webui/utils/models.py directly: a model with NO `model` table row
#    is admin-only by design ("no access control configured yet"), and a
#    model WITH a row but no access_grant is *also* invisible to anyone but
#    its owner - zero access grants existed, so a second webui user
#    (non-admin) could see no models at all, not even the two that already
#    had rows. "Public" here means "any of this instance's already-approved
#    accounts" - ENABLE_SIGNUP=false gates who can have an account at all,
#    this only controls what an existing account can see.
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
# Every model that should be selectable by non-admin webui users.
PUBLISH_MODELS=(qwen2.5-coder:7b llama3.2:3b qwen3-235b qwen3-coder-480b)
# Subset of the above that also needs the legacy function_calling override.
# qwen3-coder-480b is deliberately excluded - its dedicated qwen3_coder
# tool-call parser works correctly, no override needed.
LEGACY_MODELS=(qwen2.5-coder:7b llama3.2:3b qwen3-235b)

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

log "publishing (public read grant): ${PUBLISH_MODELS[*]}"
log "  + legacy function_calling override for: ${LEGACY_MODELS[*]}"
python3 - "$DB" "${#LEGACY_MODELS[@]}" "${LEGACY_MODELS[@]}" "${PUBLISH_MODELS[@]}" <<'PY'
import sqlite3, json, time, sys, uuid

db_path = sys.argv[1]
n_legacy = int(sys.argv[2])
legacy_models = sys.argv[3:3 + n_legacy]
publish_models = sys.argv[3 + n_legacy:]

db = sqlite3.connect(db_path)
cur = db.cursor()
row = cur.execute("SELECT id FROM user ORDER BY created_at ASC LIMIT 1").fetchone()
if not row:
    print("no user row found - skipping")
    sys.exit(0)
user_id = row[0]
now = int(time.time())

for model_id in publish_models:
    params = {"function_calling": "legacy"} if model_id in legacy_models else {}
    cur.execute(
        """INSERT OR REPLACE INTO model
           (id, user_id, base_model_id, name, params, meta, updated_at, created_at, is_active)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)""",
        (model_id, user_id, model_id, model_id,
         json.dumps(params),
         json.dumps({"capabilities": {"vision": False}}),
         now, now),
    )
    # Public read grant = principal_type 'user', principal_id '*' (open_webui/models/access_grants.py).
    # Delete-then-insert instead of relying on a unique index we haven't
    # confirmed exists - keeps this idempotent regardless.
    cur.execute(
        """DELETE FROM access_grant
           WHERE resource_type='model' AND resource_id=? AND principal_type='user'
             AND principal_id='*' AND permission='read'""",
        (model_id,),
    )
    cur.execute(
        """INSERT INTO access_grant
           (id, resource_type, resource_id, principal_type, principal_id, permission, created_at)
           VALUES (?, 'model', ?, 'user', '*', 'read', ?)""",
        (str(uuid.uuid4()), model_id, now),
    )

db.commit()
print(f"published {len(publish_models)} model(s), {len(legacy_models)} with the legacy override, as user {user_id}")
PY

if [[ "$WAS_UP" -eq 1 ]]; then
  log "restarting webui..."
  "$(dirname "$0")/svc.sh" start webui
fi

log "done."
