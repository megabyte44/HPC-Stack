# Quota-safe LLM + workflow stack on a shared GPU cluster

No sudo. No Docker. Nothing heavy in `$HOME`.

## Architecture

```
  Laptop                    sastra-master-node          dgx-node1
  ------                    ------------------          ---------
  browser :8080  ──┐
  browser :5678  ──┤                                    ollama    :11434 ─┐
  curl    :11434 ──┼── ssh -N gpu-tunnel ──ProxyJump──> open-webui:8080  ─┤ all bound to
  code    :4000  ──┘                                    n8n       :5678  ─┤ 127.0.0.1 only
                                                        litellm   :4000  ─┘
                            $HOME (quota'd)             /tmp/hackathon01_work (no quota)
                            └── hpc-stack/  ~200 KB     ├── opt/    toolchains
                                                        ├── models/ weights + HF cache
                                                        ├── cache/  pip, npm, uv, triton
                                                        ├── apps/   n8n db, webui db
                                                        └── logs/
```

Everything binds to loopback. The only way in is your SSH tunnel, which means
you get authentication for free and you are not exposing a model endpoint to
everyone else on the cluster.

## File map

```
sastra-master-node + dgx-node1 (shared NFS $HOME)
│
└── ~/                                               ← your NFS home, permanent, backed up nowhere but here + GitHub
    │
    └── hpc-stack/                                    ← the whole knowledge base (~200 KB)
        │
        ├── README.md                 [git]  operator guide: architecture, install order, daily use (this file)
        ├── KNOWLEDGE.md               [git]  runbook: mistakes made, fixes, model choices, quick reference
        ├── BOOTSTRAP.md               [git]  total-loss recovery, no AI needed
        ├── .gitignore                 [git]  excludes the 5 secret files below, on purpose
        │
        ├── 00-env.sh                  [git]  single source of truth: every path/port/env var
        ├── 10-toolchain.sh            [git]  installs ollama, node, uv onto $WORK
        ├── 20-apps.sh                 [git]  installs open-webui, n8n, litellm, moto, cloudflared
        ├── svc.sh                     [git]  process supervisor: start/stop/restart/status/logs/pull
        ├── doctor.sh                  [git]  health check + $HOME leak check + exposure audit
        ├── restore-all.sh             [git]  disaster recovery after a $WORK wipe (reboot)
        ├── fix-webui-toolcalling.sh   [git]  reapplies the §5.4 tool-calling override
        ├── coder-ctl.sh               [git]  on-demand qwen3-coder-480b: coder start/status/stop
        ├── vllm-ctl.sh                [git]  always-on qwen3-235b, manual control: general start/status/stop
        ├── coder-idle-watch.sh        [git]  auto-stops coder after idle timeout (§4a)
        ├── comfyui-idle-watch.sh      [git]  releases comfyui's VRAM (not the process) when idle (§4a.1)
        ├── keepalive.sh               [git]  touches $WORK so idle-reaper doesn't sweep it
        ├── bashrc-snippet.sh          [git]  wires env vars + aliases (svc, doctor, gpu) into .bashrc
        ├── laptop-ssh-config.example  [git]  SSH tunnel config template for YOUR laptop
        │
        ├── .hf_token                  [local only]  HuggingFace token — re-fetchable from hf.co/settings/tokens
        ├── .litellm_master_key        [local only]  auto-regenerates if missing, no action needed
        ├── .cloudflare_tunnel_token   [local only]  re-fetchable from Cloudflare Zero Trust dashboard
        ├── .n8n_owner_password        [local only]  your own note of the n8n signup password — irrecoverable if lost
        ├── .webui_new_password        [local only]  your own note of the Open-WebUI admin password — same
        └── .git/                                    pushed to github.com/megabyte44/HPC-Stack

/tmp/hackathon01_work/  ($WORK — node-local on dgx-node1 ONLY, does NOT survive reboot)
│
├── opt/            toolchains: ollama, node, uv, uv-managed python, uv-tools (vllm, litellm, open-webui...)
│   └── bin/         every installed executable lands here (on PATH)
├── apps/           app state
│   ├── open-webui/  webui.db (chat history, users, model overrides)
│   ├── n8n/         .n8n/database.sqlite (workflows, credentials)
│   ├── litellm/     config.yaml (model routing, master key)
│   └── comfyui/     ComfyUI clone + venv (only present if `restore-all.sh --comfyui` was run)
├── cache/          pip, npm, uv, triton, nv, matplotlib, etc. — everything redirected off $HOME
├── models/         ollama blobs + HF hub cache (this is the multi-hundred-GB stuff)
├── logs/           one .log per service (`svc.sh logs <name>` tails these)
├── run/            pid files (svc.sh's bookkeeping)
└── venvs/
```

The `[git]` tag means it's tracked and pushed to GitHub — recoverable with
`git clone` alone. `[local only]` means it exists only on this NFS home and
is excluded from git on purpose (`.gitignore`) — see `BOOTSTRAP.md` §2 for
which of those auto-regenerate, which are re-fetchable from an external
dashboard, and which are gone for good if you don't back them up yourself.
The `$WORK` tree is node-local to `dgx-node1` and rebuilt from scratch by
`restore-all.sh` any time it's wiped.

## Install order

```bash
# 1. From your laptop, copy the bundle to the cluster:
scp -r hpc-stack <USER>@<MASTER>:~/

# 2. On the master node, wire up the shell:
ssh <USER>@<MASTER>
chmod +x ~/hpc-stack/*.sh
cat ~/hpc-stack/bashrc-snippet.sh >> ~/.bashrc
source ~/.bashrc

# 3. On the GPU node, build the stack:
ssh dgx-node1
bash ~/hpc-stack/10-toolchain.sh     # ollama, node, uv     (~2 min)
bash ~/hpc-stack/20-apps.sh          # open-webui, n8n      (~10 min, ~6 GB)
bash ~/hpc-stack/svc.sh start all
bash ~/hpc-stack/svc.sh pull llama3.1:8b
bash ~/hpc-stack/doctor.sh           # confirm $HOME is still clean

# 4. On your laptop:
#    merge laptop-ssh-config.example into ~/.ssh/config, then:
ssh -N gpu-tunnel
#    open http://localhost:8080
```

## Daily use

```bash
svc status              # what is running, GPU usage, disk usage
svc start n8n
svc restart ollama
svc logs webui          # tail -f
svc pull qwen2.5-coder:7b
doctor                  # leak check - run after any new pip/npm install
```

`svc` works from the master node too; it detects the wrong hostname and
re-executes itself over SSH to `dgx-node1`.

### On-demand qwen3-coder-480b (doesn't permanently pin 4 GPUs)

```bash
coder start     # picks free GPUs fresh (nvidia-smi), launches, waits for ready (minutes)
coder status    # up/down, which GPUs, health, idle-watch state
coder stop      # stops it and releases the GPUs immediately
```

Auto-stops itself after 15 min with no requests (`CODER_IDLE_TIMEOUT` in
`00-env.sh`) — no need to remember `coder stop` most of the time. There's
no Slurm on this node (see `KNOWLEDGE.md` §4a for why), so GPU picking is
a fresh `nvidia-smi` check each time, same as everything else on this
shared box — not scheduler-enforced isolation, just never stale.

### qwen3-235b — always-on, stop it only when you choose to

```bash
general start     # picks free GPUs fresh, launches, waits for ready (minutes)
general status    # up/down, which GPUs, health
general stop      # your call, any time - releases the GPUs
```

Deliberately **no idle-timeout** — this is the one you keep as
general-purpose/default, so it stays up until you explicitly stop it,
same GPU-picking discipline as `coder` otherwise (fresh `nvidia-smi`
check, no stale hardcoded GPU list). Aliased to `general`, not `vllm` —
`vllm` is already the real CLI binary on `$PATH`.

### ComfyUI idle VRAM release (process stays up, GPU1's memory doesn't have to)

```bash
svc start comfyui-watch   # safe to run any time comfyui is already up
```

Different problem from `coder`: ComfyUI's process is cheap to leave
running, but it caches loaded models in VRAM indefinitely between
generations with no idle-unload of its own — found ~54GB sitting on GPU1
overnight with an empty queue. This calls ComfyUI's own `POST /free` once
the queue's been empty for `COMFYUI_IDLE_TIMEOUT` (15m default) — VRAM
releases, process/UI stays up, next generation just reloads what it
needs. See `KNOWLEDGE.md` §4a.1.

## Using the model as an API

Ollama is OpenAI-compatible out of the box. With the tunnel up, from your laptop:

```bash
curl http://localhost:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.1:8b","messages":[{"role":"user","content":"hi"}]}'
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")
r = client.chat.completions.create(
    model="llama3.1:8b",
    messages=[{"role": "user", "content": "hi"}])
```

Add LiteLLM (`svc start litellm`, port 4000) when you want one endpoint that
fronts several models with real API keys, per-key budgets and request logging.
Edit `$WORK/apps/litellm/config.yaml` and change `master_key` before you rely on it.

## Talking to qwen3-235b / qwen3-coder-480b from Open-WebUI

The two big models run under vLLM, not Ollama, so `OLLAMA_BASE_URL` never
sees them — Open-WebUI needs a *second*, OpenAI-style connection for that.
`00-env.sh` sets `ENABLE_OPENAI_API`/`OPENAI_API_BASE_URLS`/`OPENAI_API_KEYS`
to point at LiteLLM (`http://127.0.0.1:4100/v1`, offset ports) automatically,
so as long as `litellm` and `vllm`/`coder` are all up (`svc status`), both
big models just appear in webui's model picker — no manual "Add Connection"
click needed, and it survives a `webui.db` rebuild since it's env-driven,
not stored state. If they don't show up: confirm `svc status` shows
`litellm` up and `.litellm_master_key` exists, then restart webui
(`svc restart webui`) so it re-reads the env.

For tool-calling / agent use specifically, `qwen3-235b` needs the same
`legacy` function-calling override as the small Ollama models (its
`qwen3_xml` parser is buggy — KNOWLEDGE.md §5.4); `fix-webui-toolcalling.sh`
covers all three. `qwen3-coder-480b` doesn't need it.

## Wiring n8n to the model

Inside n8n, everything is node-local, so **do not** use the tunnel:

- Credential type: *Ollama* → Base URL `http://127.0.0.1:11434`
- Or an *OpenAI* credential → Base URL `http://127.0.0.1:4000/v1`, key = your LiteLLM master key
- Then use the **Basic LLM Chain** or **AI Agent** node.

Webhook nodes will show a URL of `http://localhost:5678/webhook/...`. That is
reachable from your laptop while the tunnel is up, and from anything else on
`dgx-node1`. It is *not* reachable from the public internet, which is usually
what you want on a shared cluster. If a workflow needs to receive events from an
external SaaS, use n8n's polling triggers instead of webhooks, or add an
outbound tunnel service — do not try to bind n8n to `0.0.0.0`.

## Local AWS emulation (Moto — no Docker needed)

`svc start moto` runs [Moto](https://github.com/getmoto/moto) in server mode
on `$MOTO_PORT` (5100 with the offset) — a LocalStack-style mock of most AWS
APIs (S3, DynamoDB, SQS, SNS, Lambda, IAM, and more) as one plain Python
process, no container runtime involved. Point any AWS SDK or the `aws` CLI
at it instead of real AWS:

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://127.0.0.1:5100 s3 mb s3://test-bucket
```

```python
import boto3
s3 = boto3.client("s3", endpoint_url="http://127.0.0.1:5100")
s3.create_bucket(Bucket="test-bucket")
```

State is in-memory only — it resets every time you `svc restart moto`,
which is normally what you want for learning/testing. Credentials can be
any non-empty string; Moto doesn't check them.

## Exposing a service beyond your SSH tunnel (Cloudflare Tunnel)

Everything above assumes the *only* way in is your SSH key (`gpu-tunnel`).
`cloudflared` (`svc start cloudflared`, one more entry in the supervisor,
no port of its own — it dials *out* to Cloudflare's edge) breaks that
assumption: whatever local port you point a Public Hostname at in the
Cloudflare dashboard becomes reachable by anyone on the internet who has
the URL, not just people with your SSH key. That's a real step up in
exposure, so treat it deliberately, not as "just another service to start."

Setup:

```bash
echo '<your-tunnel-token>' > ~/hpc-stack/.cloudflare_tunnel_token
chmod 600 ~/hpc-stack/.cloudflare_tunnel_token
svc start cloudflared
```

Then, in the Cloudflare dashboard, add a **Public Hostname** route per
service you want reachable, pointing at `http://127.0.0.1:<port>` (your
node's offset ports — check `svc status`). Before routing anything:

- **n8n**: has no auth of its own until an owner account exists — whoever
  loads the UI *first* claims it. Open n8n through your SSH tunnel and sign
  up **before** adding the public route. `doctor.sh`'s EXPOSURE section
  checks this for you.
- **open-webui**: `ENABLE_SIGNUP=false` is already set, so only your first
  account can ever self-register — same rule, claim it over the SSH tunnel
  first.
- **ollama's raw port**: has no auth at all. Don't route a public hostname
  straight at it — anyone could run unlimited inference on the cluster's
  GPUs for free. Route **litellm** instead; it requires its `master_key` on
  every request (`$WORK/apps/litellm/config.yaml`).
- **jupyter**, if you add it later: never disable its token. A public
  hostname pointed at an unauthenticated Jupyter kernel is remote code
  execution for anyone who finds the URL.
- For a real second factor beyond "the app's own login," put a **Cloudflare
  Access** policy in front of the hostname — it authenticates the visitor
  before they ever reach the service.

## Disaster recovery

- `$WORK` wiped (node reboot) but `~/hpc-stack/` still here → `restore-all.sh`,
  see `KNOWLEDGE.md` §4.
- `~/hpc-stack/` itself gone (deleted home, new account, new cluster) →
  `BOOTSTRAP.md`. Written to be followed with no prior context and no AI
  assistance — start there if everything is gone.

## Things that will bite you

**`/tmp` is not permanent.** Many clusters delete files untouched for 7–14 days,
and a node reboot may clear it outright. Recovery is just re-running
`10-toolchain.sh` and `20-apps.sh` — but your n8n workflows live in
`$WORK/apps/n8n`, so back those up to `$HOME` periodically. They are small:

```bash
n8n export:workflow --all --output ~/hpc-stack/backup/workflows.json
n8n export:credentials --all --decrypted=false --output ~/hpc-stack/backup/creds.json
```

To reduce the odds of the reaper touching you, keep timestamps fresh while you
are active: `find "$WORK" -depth -exec touch -a {} + 2>/dev/null`.

**`.bashrc` and non-interactive SSH.** Ubuntu's default `.bashrc` returns early
for non-interactive shells, so `ssh dgx-node1 'ollama list'` gets none of your
env vars. Every script here sources `00-env.sh` explicitly for that reason. If
you want ad-hoc SSH commands to work too, move the hpc-stack block *above* the
`case $- in *i*) ;; *) return;; esac` line in `.bashrc`.

**Port collisions.** You share the node. If `svc start` reports a port in use,
set `export HPC_PORT_OFFSET=100` in your `.bashrc` and update the
`LocalForward` lines in your laptop SSH config to match.

**Shared GPUs.** `nvidia-smi` before you load a 70B model. Pin yourself with
`export CUDA_VISIBLE_DEVICES=2` if the cluster has no scheduler enforcing
allocation, and keep `OLLAMA_MAX_LOADED_MODELS` low so you release VRAM.

**`chmod 700 $WORK`.** Other users can read `/tmp`. The installer sets this, but
check it after any manual `mkdir`.

## Model sizing (rough VRAM, Q4 quantised)

| Model | VRAM | Good for |
|---|---|---|
| `qwen2.5:3b` | ~3 GB | fast n8n classification/routing steps |
| `llama3.1:8b` | ~6 GB | general chat, the safe default |
| `qwen2.5-coder:7b` | ~6 GB | code generation |
| `mistral-small:24b` | ~15 GB | stronger reasoning |
| `llama3.3:70b` | ~42 GB | only on a mostly-idle A100/H100 |

Run a small model for workflow glue and a large one for the actual reasoning
step — `OLLAMA_MAX_LOADED_MODELS=2` keeps both resident.

## If you outgrow Ollama

Ollama serialises poorly under real concurrency. When you need throughput,
`uv tool install vllm` into the same `$WORK` tree and run it on a second port;
it is also OpenAI-compatible, so LiteLLM can front both and nothing downstream
changes. The trade-off is one model per process and a much heavier install.
