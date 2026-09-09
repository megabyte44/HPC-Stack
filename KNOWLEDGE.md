# HPC Stack — Knowledge Base & Runbook

This is the persistent record of how this stack works, why it's built this way,
and every mistake made building it — so a new session (human or Claude) can
get productive in minutes instead of rediscovering all of this the hard way.

Lives at `~/hpc-stack/KNOWLEDGE.md` (NFS home — survives node reboots, unlike
everything under `$WORK`).

## 1. The topology

- `sastra-master-node` — login node. You start here. No GPUs.
- `dgx-node1` — 8x NVIDIA H200 (143GB each), reached via `ssh dgx-node1`
  (ProxyJump through the master node). This is a **shared, multi-tenant box**
  — other users run jobs on it too. Always check `nvidia-smi` before claiming
  GPUs; never touch a GPU already showing heavy memory use from another PID.
- No sudo, no Docker. Everything is user-space (`uv`, raw binaries, venvs).

## 2. The two-tier storage model (the single most important thing to know)

| Path | Backing | Survives reboot? | What goes here |
|---|---|---|---|
| `~/hpc-stack/` (`$HOME`) | NFS (GPFS, `fs_gpfs01`) | **Yes** | Scripts, secrets, docs — this file |
| `/tmp/hackathon01_work` (`$WORK`) | node-local disk on `dgx-node1` | **No** | Everything installed: toolchains, model weights, app databases, logs, running services |

`$WORK` is node-local specifically so multi-hundred-GB model downloads don't
touch the NFS home quota. The trade-off: **a `dgx-node1` reboot wipes
`$WORK` completely.** This has already happened once (2026-09-08 — node
rebooted overnight, uptime resets, `$WORK` came back empty). It will happen
again. This is why `restore-all.sh` exists — see §4.

GPU VRAM is even more ephemeral than `$WORK`: it clears on process death,
not just reboot. After any crash/restart, previously "warm" models are gone
from GPU memory even if the downloaded weights on disk survived.

## 3. Quick reference

```
ssh dgx-node1                                  # get on the GPU box
~/hpc-stack/svc.sh status                      # what's running, GPU usage
~/hpc-stack/svc.sh logs <service>               # tail -f a service's log
~/hpc-stack/svc.sh restart <service>
bash ~/hpc-stack/doctor.sh                     # full health check + $HOME leak check
```

Services (`svc.sh`): `ollama webui n8n litellm vllm vlm coder comfyui
cloudflared moto keepalive`. Ports are `BASE + HPC_PORT_OFFSET` (offset is
100 in interactive shells via `.bashrc`; **non-interactive `ssh host 'cmd'`
skips `.bashrc`, so always `export HPC_PORT_OFFSET=100` before sourcing
`00-env.sh` by hand in a one-off SSH command**).

| Service | Real port | Purpose |
|---|---|---|
| ollama | 11534 | small local models (Ollama-native) |
| webui | 8180 | Open-WebUI chat UI |
| n8n | 5778 | workflow automation |
| litellm | 4100 | unifying OpenAI-compatible gateway in front of everything |
| vllm | 8100 | **qwen3-235b** (Qwen3-235B-A22B-Instruct-2507-FP8) |
| coder | 8800 | **qwen3-coder-480b** (Qwen3-Coder-480B-A35B-Instruct-FP8) |
| vlm | 8600 | vision model slot (Qwen2.5-VL-7B) — currently not deployed |
| comfyui | 8288 | image/video generation UI |
| moto | 5100 | AWS API emulator |
| cloudflared | - | outbound tunnel, public hostnames configured in Cloudflare dashboard |

Public hostnames — added via the Tunnel's own **Public Hostname** tab
(Zero Trust dashboard → Networks → Tunnels → your tunnel), NOT via Cloudflare
**Access** → Applications (that's a different product, asked for a payment
method even on attempted free-tier use — skip it entirely, plain tunnel
routing is free and needs no policy):
- `openweb.punith.tech` → 127.0.0.1:8180 (webui)
- `llm.punith.tech` → 127.0.0.1:4100 (litellm)
- `comfy.punith.tech` → 127.0.0.1:8288 (comfyui)

None of these have real auth in front of them beyond LiteLLM's API key
(webui and comfyui have none at all beyond their own login/nothing) —
acceptable only because a Cloudflare Access policy costs money on this
account. If that changes, put one back in front of `comfy.punith.tech`
especially (zero auth, generates on H200s, worst one to leave open).

## 4. Disaster recovery — `restore-all.sh`

After a `$WORK` wipe (reboot), from `~/hpc-stack/`:

```bash
bash ~/hpc-stack/restore-all.sh                    # toolchain + apps + base services
bash ~/hpc-stack/restore-all.sh --models           # + both big vLLM models (~717GB download)
bash ~/hpc-stack/restore-all.sh --comfyui          # + ComfyUI (clone + venv build)
bash ~/hpc-stack/restore-all.sh --models --comfyui # everything
```

Before running with `--models`, check `nvidia-smi` — the GPU defaults
baked into the script (`VLLM_GPUS`, `CODER_GPUS`) reflect the last known-good
free set, not necessarily what's free *now*. Override via env vars if
needed: `export CODER_GPUS=4,5,6,7` before running.

As of 2026-09-09, `restore-all.sh` also handles:
- **Open-WebUI's tool-calling override** (§5.4) — runs
  `fix-webui-toolcalling.sh` automatically at the end. This is a genuine
  no-op (not a failure) if you haven't signed back into Open-WebUI yet,
  since the `model`/`user` tables don't exist until you have — just
  re-run `bash ~/hpc-stack/fix-webui-toolcalling.sh` once you've signed up.
  It stops/restarts webui itself around the sqlite edit, so don't run it
  while you have unsaved work in the webui UI.
- **ComfyUI** — `restore-all.sh --comfyui` clones + builds the venv (still
  deliberately on `$WORK`, not NFS `$HOME` — see §5.7). You still start it
  yourself once you've picked a free GPU: `export COMFYUI_GPU=<n>;
  ~/hpc-stack/svc.sh start comfyui`. Takes ~15-20 min total (torch install
  is the slow part, more if the two big vLLM downloads are saturating the
  link at the same time).

What still has no automation:
- **Vision model (`vlm`)** — deprioritized, not currently deployed at all.
- **SGLang** — see §6, not installed.

For total loss — `~/hpc-stack` itself gone, not just `$WORK` — see
`BOOTSTRAP.md`. That is the doc to follow with zero prior context and no
AI assistance; this file assumes `~/hpc-stack` still exists.

## 5. Mistakes made and what actually fixed them

### 5.1 CUDA driver ceiling
`dgx-node1`'s NVIDIA driver only supports up to **CUDA 12.8**. Any package
built against CUDA 13 (the default in recent PyTorch/vLLM releases) fails
at import/runtime with something like `libcudart.so.13: cannot open shared
object file`, even though it installed fine. **Fix: always pass
`--torch-backend cu128`** to `uv pip install`/`uv tool install` for anything
touching torch.

### 5.2 vLLM version pin
Even with `--torch-backend cu128`, vLLM ≥0.24.0 ships compiled extensions
hard-linked to CUDA 13 regardless of the paired torch build. **Pin
`vllm==0.11.0`** specifically — confirmed working via bisection.

### 5.3 transformers version pin
`vllm==0.11.0`'s tokenizer code is incompatible with `transformers>=5.x`
(`AttributeError: Qwen2Tokenizer has no attribute
all_special_tokens_extended`). **Pin `transformers==4.57.6`** into the vllm
tool env: `uv pip install --python <vllm-venv>/bin/python transformers==4.57.6`.

### 5.4 vLLM tool-call parser bugs / Ollama has no real tool calling
Two distinct but same-shaped problems:
- **`qwen3_xml` parser (vLLM 0.11.0) is buggy** for `Qwen3-235B-A22B-Instruct`:
  produces tool calls with `function.name: None`, which then makes vLLM
  choke re-parsing its own output on the next turn. There's no newer-vLLM
  fix available (newer vLLM breaks on this driver, see §5.2). **Workaround:
  force `function_calling: "legacy"`** for this model in Open-WebUI (client-side
  prompt injection instead of real API tool declarations) — bypasses the
  broken parser entirely.
- **Ollama-served small models (`qwen2.5-coder:7b`, `llama3.2:3b`) don't
  support real structured tool-calling at all.** When a client declares
  `toolCalling: true` and sends a `tools` array, these models just
  hallucinate JSON-shaped text in the `content` field (e.g. `{"name":
  "greet", "arguments": {}}` or `{"name": "ask_user", ...}` — sometimes
  matching a real tool name, sometimes not) with `finish_reason: "stop"`,
  not a real `tool_calls` array. Any client that trusts the `toolCalling:
  true` declaration (VS Code Copilot, Open-WebUI's "Native" mode) will
  either crash trying to parse it or just display the raw JSON as a
  "response". **Fix: same as above — force `function_calling: "legacy"`**
  for these models in Open-WebUI, and set `toolCalling: false` in any
  external client's model config (VS Code Copilot's `settings.json`,
  Continue's `config.yaml`).
  - By contrast, `Qwen3-Coder-480B-A35B-Instruct` via vLLM's dedicated
    `qwen3_coder` tool parser (distinct from the buggy `qwen3_xml` one)
    **does work correctly** — no workaround needed there.

  Script to reapply the Open-WebUI fix after any `webui.db` rebuild
  (run on `dgx-node1`, stop webui first):
  ```python
  import sqlite3, json, time
  db = sqlite3.connect("$DATA_DIR/webui.db")
  cur = db.cursor()
  now = int(time.time())
  user_id = "<your open-webui user id, SELECT id FROM user>"
  for model_id in ["qwen2.5-coder:7b", "llama3.2:3b"]:
      cur.execute("""INSERT OR REPLACE INTO model
          (id, user_id, base_model_id, name, params, meta, updated_at, created_at, is_active)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)""",
          (model_id, user_id, model_id, model_id,
           json.dumps({"function_calling": "legacy"}),
           json.dumps({"capabilities": {"vision": False}}),
           now, now))
  db.commit()
  ```

### 5.5 vLLM multi-instance port race
Starting two `vllm serve` processes back-to-back (e.g. in a script) races
them onto the same auto-picked internal distributed-rendezvous port. Looks
like a random crash (`EADDRINUSE` on one, cryptic gloo `Connection closed by
peer` on the other) — **not** an OOM or model bug, easy to misdiagnose as
one. **Fix: don't start multiple vLLM instances simultaneously — add a
~30s sleep between `svc.sh start vllm` and `svc.sh start coder`** (already
baked into `restore-all.sh`).

### 5.6 "Free memory less than desired GPU memory utilization"
Not always a real capacity problem — check `nvidia-smi` fresh before
assuming. On a shared box, a GPU that showed 0MB used ten minutes ago can
have another user's job on it now. **Always re-check `nvidia-smi`
immediately before picking `VLLM_GPUS`/`CODER_GPUS`**, don't reuse stale
numbers from earlier in a conversation/session.

### 5.7 GPFS quota is real but invisible to normal tools
`quota -s` and `df -h` show nothing useful (GPFS quotas, if any, aren't
exposed that way — `mmlsquota` may report "No quota enabled file system
found" even when writes still fail). A multi-GB write to NFS `$HOME` (e.g.
ComfyUI's torch-heavy venv) failed once with `No space left on device`
despite `df` showing terabytes free — this looks identical to storage
*instability*, not a quota, and cost real time to diagnose. **Practical
rule: keep heavy venvs (anything pulling torch/CUDA libs) on `$WORK`
(node-local), never on NFS `$HOME`, regardless of how much free space `df`
claims.** Small text/script files on `$HOME` are fine and always have been.

### 5.8 LiteLLM config auto-regeneration trap
`20-apps.sh`'s litellm install step used to **write a fresh
`config.yaml` with a brand-new random master key** every time the file
didn't exist — including after a `$WORK` wipe. Silently breaks every
already-configured external client (VS Code, curl scripts) pointing at the
old key, and drops any custom model entries back to the hardcoded default
list. **Fixed at the source**: `20-apps.sh` now reuses the master key from
`~/hpc-stack/.litellm_master_key` if present (writes it there if not), and
its default template includes the real model list (`qwen3-235b`,
`qwen3-coder-480b`), not just the two Ollama fallbacks.

### 5.9a "No available memory for the cache blocks" / GPU contention drift
Even after a vLLM instance loads its weights successfully, it can still fail
a few seconds later with `ValueError: No available memory for the cache
blocks` or `... KV cache is needed, which is larger than the available KV
cache memory`. This means the weights fit but there wasn't enough left over
for the KV cache — almost always because **another user's job grew on one
of your GPUs between when you checked `nvidia-smi` and when the engine
finished initializing** (this is a busy shared box; GPU free memory is not
stable from one minute to the next). Two independent knobs to recover
headroom, **`gpu_memory_utilization` and `max_model_len` trade against each
other** — prefer lowering `max_model_len` first: it doesn't depend on the
other tenant's usage staying put, whereas nudging `gpu_memory_utilization`
up toward the edge of what's currently free can immediately re-fail if
their job grows again. Concretely: dropped `qwen3-235b` from
`--max-model-len 32768` to `24576` at `--gpu-memory-utilization 0.85` and it
came up clean. **General rule for this box: always re-check `nvidia-smi`
immediately before *every* `svc.sh start vllm`/`start coder`, even a
retry of something that worked minutes ago** — don't assume yesterday's
(or five-minutes-ago's) GPU pick is still safe.

### 5.9b vLLM keeps a model loaded forever — no Ollama-style auto-unload
Ollama unloads idle models from VRAM automatically (`OLLAMA_KEEP_ALIVE`).
**vLLM does not** — once `vllm serve` loads a model it stays resident in
GPU memory for the life of the process, active or fully idle, no built-in
idle timeout. On this box `qwen3-235b` + `qwen3-coder-480b` permanently pin
6 of 8 GPUs the instant both are started, whether or not anyone is
chatting. To free GPUs for another job, you must explicitly
`~/hpc-stack/svc.sh stop vllm` / `stop coder` — there's no automatic
"dynamic" behavior; "dynamic loading" on this stack means a human (or a
cron/watchdog you'd have to build yourself) explicitly starting/stopping
services around actual usage windows.

### 5.9 vLLM AWQ requires `--dtype float16`
`torch.bfloat16` is not supported for AWQ-quantized models in this vLLM
version — fails with a pydantic validation error at startup, not obviously
related to dtype at first glance. **Add `--dtype float16` whenever serving
an AWQ checkpoint.**

### 5.10 VS Code Copilot custom-endpoint gotchas
- The endpoint's top-level `"name"` field **is the base URL**, not just a
  display label — appending anything to it (e.g. `/models`) breaks every
  request silently (all requests go to the wrong path, client shows
  `Cannot read properties of undefined (reading 'includes')`, a useless
  error for diagnosing this).
- Each model entry needs a `"url"` key present (empty string `""` is fine)
  — omitting it entirely fails schema validation and the model silently
  doesn't appear in the picker, no visible error pointing at the real cause.
- New models added by hand-editing `settings.json` may need enabling via
  the separate **"Manage Models..."** UI (distinct from what's merely
  *defined* in settings.json) before they show up in the model picker.
- `maxInputTokens + maxOutputTokens` must stay under the server's actual
  `--max-model-len` (check per model — this drifts, see §5.9a; was reduced
  to 24576 for qwen3-235b, still 32768 for qwen3-coder-480b as of last
  check, always confirm against the live `svc.sh logs vllm`/`logs coder`
  startup line rather than trusting this doc) or long requests error out
  server-side.
- Continue (`~/.continue/config.yaml`) has been consistently easier to get
  working correctly than Copilot's custom-endpoint integration for this
  setup — prefer it if Copilot keeps misbehaving.

### 5.11 Stray duplicate scripts
A second, stale, out-of-date copy of the hpc-stack scripts existed at
`~/home/files/` (dated before today's fixes — including the broken
litellm-config-regeneration bug from §5.8). Nothing under `~/home/` was
ever the canonical copy; `~/hpc-stack/` always is. If in doubt about which
copy of a script is real, canonical location is always `~/hpc-stack/`.

## 6. Model choices and why

- **qwen3-235b** = `Qwen/Qwen3-235B-A22B-Instruct-2507-FP8`. FP8 chosen over
  BF16 (~470GB) specifically to make the download/VRAM footprint tractable
  on a shared box. TP=2 (GPU head-count constraints: 64 attention heads / 4
  KV heads — TP must divide both evenly; 2 and 4 both valid, 2 chosen to
  leave more GPUs free for the coder model).
- **qwen3-coder-480b** = `Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8`. TP=4
  (96 attention heads / 8 KV heads — divides evenly by 4). An AWQ 4-bit
  variant (`TechxGenus/Qwen3-Coder-480B-A35B-Instruct-AWQ`, ~261GB vs
  ~482GB FP8) was used once as a fallback when free GPU headroom was too
  tight for FP8 — same architecture/capability, meaningfully smaller
  download, slightly lower quality. Switch back to it (`--quantization awq
  --dtype float16`, see §5.9) if GPU/disk pressure ever makes FP8
  infeasible again.
- Both wired into LiteLLM (`hosted_vllm/<served-model-name>` provider
  prefix) so any OpenAI-compatible client (Open-WebUI, VS Code, Continue,
  curl) reaches them through one gateway/one API key.
- **SGLang** — named in the target architecture (UI: Open-WebUI/ComfyUI/n8n;
  serving: Ollama/vLLM/SGLang/LiteLLM) but **not installed yet**. Would be a
  third serving slot alongside `vllm`/`coder` in `svc.sh`, same
  `hosted_vllm/`-style LiteLLM wiring pattern (SGLang's own OpenAI-compat
  server). Same CUDA-12.8 ceiling from §5.1 will apply — check SGLang's own
  torch/CUDA compatibility matrix before installing, don't assume the vLLM
  0.11.0 pin transfers over.

## 7. Onboarding prompt for a new session

Paste this at the start of a new Claude Code session working on this stack:

> I'm working on an AI/ML inference stack on a shared HPC cluster
> (`sastra-master-node` login node, `dgx-node1` compute node with 8x H200,
> reached via `ssh dgx-node1`). Everything is documented in
> `~/hpc-stack/KNOWLEDGE.md` on `dgx-node1` — read it before doing anything.
> Key facts: `~/hpc-stack/` (NFS home) is permanent and holds all scripts +
> secrets; `/tmp/hackathon01_work` (`$WORK`, node-local) holds everything
> installed and does NOT survive a `dgx-node1` reboot. Use `svc.sh` to
> manage services, `doctor.sh` for health checks, `restore-all.sh` for
> disaster recovery after a reboot. Always `export HPC_PORT_OFFSET=100`
> before sourcing `00-env.sh` in a non-interactive `ssh host 'cmd'` (it's
> only set automatically in interactive shells via `.bashrc`). Check
> `nvidia-smi` fresh before picking GPUs — this is a shared box, other
> users' jobs move around.
