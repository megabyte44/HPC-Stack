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

Services (`svc.sh`): `ollama webui n8n litellm vllm coder coder-watch
comfyui comfyui-watch cloudflared moto keepalive`. Ports are `BASE +
HPC_PORT_OFFSET` (offset is 100 in interactive shells via `.bashrc`;
**non-interactive `ssh host 'cmd'` skips `.bashrc`, so always `export
HPC_PORT_OFFSET=100` before sourcing `00-env.sh` by hand in a one-off SSH
command**).

| Service | Real port | Purpose |
|---|---|---|
| ollama | 11534 | small local models (Ollama-native) |
| webui | 8180 | Open-WebUI chat UI |
| n8n | 5778 | workflow automation |
| litellm | 4100 | unifying OpenAI-compatible gateway in front of everything |
| vllm | 8100 | **qwen3-235b** (Qwen3-235B-A22B-Instruct-2507-FP8), always-on |
| coder | 8800 | **qwen3-coder-480b**, on-demand (§4a) — `coder start/status/stop` |
| coder-watch | - | idle-timeout auto-stop for `coder` (§4a) |
| comfyui | 8288 | image/video generation UI |
| comfyui-watch | - | idle VRAM release for `comfyui`, process stays up (§4a.1) |
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
- `agents.punith.tech` → 127.0.0.1:5778 (n8n) — added 2026-09-09, needed a
  matching `WEBHOOK_URL` change to work at all, see §5.12

None of these have real auth in front of them beyond LiteLLM's API key
and n8n's own owner-account login (webui and comfyui have none at all
beyond their own login/nothing) — acceptable only because a Cloudflare
Access policy costs money on this account. If that changes, put one back
in front of `comfy.punith.tech`
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
baked into the script (`VLLM_GPUS=0,3`, `CODER_GPUS=2,4,5,6` as of
2026-09-09) reflect the last known-good free set, not necessarily what's
free *now*. Override via env vars if needed, e.g. `export
CODER_GPUS=1,4,5,6` before running. Last confirmed live mapping (this
drifts — always re-check with `nvidia-smi` / `svc status` rather than
trusting this table):

| GPU | Ours? | What |
|---|---|---|
| 0 | shared | `vllm` (qwen3-235b) TP rank 0, + other users' unrelated jobs |
| 1 | ours only | `comfyui` — usually the one with real headroom |
| 2 | shared | `coder` (qwen3-coder-480b) TP rank 0 |
| 3 | shared | `vllm` (qwen3-235b) TP rank 1 |
| 4 | ours only | `coder` (qwen3-coder-480b) TP rank 1 |
| 5 | ours only | `coder` (qwen3-coder-480b) TP rank 2 |
| 6 | ours only | `coder` (qwen3-coder-480b) TP rank 3 |
| 7 | **not ours** | another user's own vLLM job — don't target this one |

To reproduce this table yourself: `nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader`
cross-referenced with `nvidia-smi --query-gpu=index,uuid --format=csv,noheader`
for the index, and `tr '\0' '\n' < /proc/<pid>/environ | grep CUDA_VISIBLE_DEVICES`
(pids from `svc status`) for which of our services owns which index.

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
- **SGLang** — see §6, not installed.

For total loss — `~/hpc-stack` itself gone, not just `$WORK` — see
`BOOTSTRAP.md`. That is the doc to follow with zero prior context and no
AI assistance; this file assumes `~/hpc-stack` still exists.

## 4a. On-demand `coder` (qwen3-coder-480b) — no permanent GPU pinning

Confirmed 2026-09-09: **Slurm cannot be used to schedule anything on
`dgx-node1`.** This isn't a policy choice, it's a hard technical fact,
checked directly:

- `scontrol show node dgx-node1` → `Node dgx-node1 not found`. Slurm's
  actual configured nodes (`/etc/slurm/slurm.conf`) are `gpunode1`
  (172.16.13.102) and `gpunode2` (172.16.13.103) — **different physical
  machines** from `dgx-node1` (172.16.13.91). Neither is usable anyway:
  `gpunode1` is `drained` ("Kill task failed"), `gpunode2` is `inval`.
- `dgx-node1` has **no `slurmd` and no `munge`** installed at all
  (`Unit slurmd.service could not be found`) — there's no daemon on this
  box to even receive an `srun`/`sbatch` request.
- `squeue` is empty cluster-wide. Every process on `dgx-node1` right now —
  ours and every other user's (Schrödinger jobs, jupyter kernels, other
  people's own raw `vllm serve` processes) — is a plain unscheduled SSH
  process, not a Slurm job. This is *why* §5.6's "always re-check
  `nvidia-smi` before picking GPUs" rule exists — there is no enforcement
  layer here at all, for anyone, not just us.

Given that, `coder-ctl.sh` (`coder start` / `coder status` / `coder stop`,
aliased via `bashrc-snippet.sh`) implements the closest honest equivalent:
a fresh `nvidia-smi` free-GPU pick (capacity-aware, not a flat threshold —
see §4a.3) at every start — the exact same check every other user on this
box already does by hand, just automatic and never stale. **This is not
scheduler-enforced isolation** — nothing on this node provides that —
it's best-effort coexistence, same guarantee level as everything else
here. If it finds fewer free GPUs than `CODER_TP_SIZE` needs, it refuses
to start rather than guessing or waiting; it never touches a GPU another
process (ours or anyone else's) already has memory
on.

Idle shutdown: `coder-idle-watch.sh` runs as the `coder-watch` svc.sh
service, polling vLLM's own `/metrics` (`vllm:request_success_total`
counter, `vllm:num_requests_running` gauge — not log timestamps, vLLM
logs periodic stats lines even at zero traffic, which would make a
log-mtime check never fire) every `CODER_POLL_INTERVAL` (60s default). No
activity for `CODER_IDLE_TIMEOUT` (900s/15m default) → `svc.sh stop
coder`, GPUs released. `coder-ctl.sh start` arms a fresh watcher every
time; `coder stop` tears both down together.

Known limitation, not hidden: a cold start loads ~450GB from disk into
VRAM, which takes real minutes (`coder start` polls `/health` for up to
20 minutes before giving up) — the first request after an idle-stop will
be slow. That's the actual cost of not permanently pinning 4 H200s; there
is no way to make disk→VRAM loading of a 480B-parameter model instant.

**Storage stayed on `/tmp` deliberately, not moved to persistent
storage**, despite that being the ideal end state: `/nfsshare` (a larger,
separate 67T NFS mount at 172.16.13.71, 7.3T free) is where many other
users' large data lives, but `hackathon01` has no directory there and
`mkdir` fails with `Permission denied` (owned `root:nogroup`, 755) — no
self-service access, would need a cluster admin to provision it. The
GPFS `$HOME` (`fs_gpfs01`, where `~/hpc-stack` itself lives) has room
filesystem-wide but §5.7 already documents a past write failure there
from an invisible per-user quota — not safe to assume it can hold 450GB
without confirming the real quota first. Revisit this once either is
resolved; until then the model re-downloads if `dgx-node1` reboots, same
as it always has.

### 4a.1 ComfyUI gets a different idle strategy, not the same one as `coder`

`qwen3-235b` (the `vllm` service) stays always-on as a general-purpose
model, deliberately — no idle-management applied to it.

ComfyUI is not like `coder` either, but for a different reason: its
*process* is cheap to leave running (no boot-time model commit like
vLLM), so a start/stop cycle isn't needed. What it does have is the same
"nothing auto-unloads" problem in a different shape — confirmed
2026-09-09 via its own `/system_stats`: **~54GB sat resident on GPU1 with
an empty queue**, left over from a session the night before. ComfyUI
caches whatever it last loaded, indefinitely, with no idle-timeout of its
own.

Fix: `comfyui-idle-watch.sh` (the `comfyui-watch` svc.sh service) polls
`/queue` every `COMFYUI_POLL_INTERVAL` (120s default); once it's been
empty for `COMFYUI_IDLE_TIMEOUT` (900s/15m default), it calls ComfyUI's
own `POST /free` (`server.py`: `{"unload_models": true, "free_memory":
true}`) — a real built-in endpoint, not a workaround. This releases VRAM
**without** killing the process/UI; the next generation just reloads
whatever checkpoint it needs, same cost as any first run. Note the
release isn't instant — PyTorch's caching allocator takes a few seconds
to actually hand pages back to the driver after the flag is set; `nvidia-smi`
lags `/free` by several seconds.

Start it any time `comfyui` is up (safe to arm on an already-running
instance, no restart needed): `svc start comfyui-watch`. Not yet wired
into `restore-all.sh --comfyui`'s startup instructions — start it
manually alongside `comfyui` for now.

### 4a.2 `vllm-ctl.sh` — same convenience as `coder`, deliberately no idle-timeout

`qwen3-235b` stays the always-on general-purpose model — that was an
explicit choice, not an oversight, so it gets `vllm-ctl.sh` (`general
start/status/stop`) instead of `coder-ctl.sh`'s pattern: same fresh
`nvidia-smi` free-GPU pick and wait-for-`/health` on start, but **no**
paired idle-watch service. It stays up until you run `general stop`
yourself. Aliased `general`, not `vllm` — that name is already the real
vLLM CLI binary on `$PATH`; aliasing over it would shadow it.
`restore-all.sh` calls `vllm-ctl.sh start` for the same reason it calls
`coder-ctl.sh start` — a hardcoded `VLLM_GPUS` default already went
stale once (§4a), no reason to keep that risk for this one too.

### 4a.3 GPU picker: capacity-aware, not a flat "touched at all" threshold

The first version of `pick_free_gpus()` (both `coder-ctl.sh` and
`vllm-ctl.sh`) required a GPU's *used* memory to be under a flat 2000 MiB
to count as a candidate. Confirmed broken 2026-09-09: with two other
users running light jobs spread thinly across GPUs 2–7 (a few GB each,
nowhere near their 143771 MiB capacity), the picker found only 1
"qualifying" GPU and refused to start `qwen3-235b` — while GPUs 2 and 6
individually had **136GB+ genuinely free**. The threshold was answering
the wrong question ("is this GPU touched at all") instead of the one
that actually matters ("is there enough room, and is anyone actively
computing on it").

Fixed: `pick_free_gpus()` now ranks by real headroom. A GPU qualifies if
`free (total - used) >= *_GPU_MIN_FREE_MIB` **and** its compute
utilization is `<= *_GPU_MAX_UTIL_PCT` (default 50 — skips a GPU someone
is actively computing on even if the memory would technically fit,
since heavy compute contention hurts both jobs regardless of VRAM
headroom); among qualifying GPUs, the ones with the most free memory are
picked first. Also now excludes any GPU already dedicated to another
always-on service of ours (`reserved_gpus()` — currently just `comfyui`'s
GPU, read live from its process env, not a static config value) — it can
look deceptively idle between generations (§4a.1's VRAM-release watcher)
but colocating a huge LLM there would starve whichever loads second the
next time both are active.

**A related mistake made live in the same incident, worth recording
separately since it's a different failure mode:** after the flat
threshold rejected everything, GPUs were picked manually and
`--gpu-memory-utilization` was lowered from `qwen3-235b`'s default 0.92
to 0.85, intending it as a "safety margin." That was backwards — it
shrank vLLM's total memory budget, and after ~117GB of weights (TP=2)
there was only 1.42GiB left for KV cache when 32768 max-model-len needs
2.94GiB: `ValueError: ... KV cache is needed, which is larger than the
available KV cache memory`. The two GPUs actually had 136GB free each —
comfortably enough for the *default* 0.92 target (~132GB) — the real fix
was picking better GPUs, not shrinking the utilization target. §5.9a's
existing advice ("prefer lowering `max_model_len` over raising
`gpu_memory_utilization` when fighting a growing neighbor") is about a
different scenario (recovering headroom against a tenant that's
currently growing); it doesn't mean lower utilization on a fresh start
against a static amount of neighbor usage — that just starves your own
KV cache. **Leave `--gpu-memory-utilization` at its proven default and
fix GPU selection instead**, which is exactly what this section's picker
change does automatically now.

**Update, same session:** the very next attempt — fresh picker, default
0.92/32768, GPUs with ~137GB free at pick time — still died, this time
with a genuine `CUDA out of memory occurred when warming up sampler with
1024 dummy requests`, ~4 minutes into loading. Neighbor usage on those
GPUs was unchanged before and after (~6.5GB), so this wasn't drift — it's
that 0.92/32768 (~132GB target) only has ~11.5GB of possible slack above
it on a totally idle 143771 MiB H200, and the warmup step's transient
memory need eats into that on top of the persistent KV-cache reservation.
There isn't a fully-idle GPU to be had reliably on this box. **Fix that
stuck this time:** dropped `VLLM_EXTRA_ARGS`' default (`vllm-ctl.sh`,
`restore-all.sh`) *and* `VLLM_GPU_MIN_FREE_MIB` together to
`--max-model-len 24576 --gpu-memory-utilization 0.85` (~122GB target,
~21.5GB max possible slack) — confirmed working end-to-end through
litellm. This matches §5.9a's own historical precedent (that section
already records this exact combo working before) — the general
principle holds: when *lowering* the memory footprint to survive a
busier box, move `max_model_len` and `gpu_memory_utilization` down
**together**, since the KV-cache requirement scales with the former and
the budget scales with the latter; moving only one starves the other.

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

### 5.12 n8n OAuth2 callback redirects to `localhost` instead of the public hostname
Setting up Gmail (or any) OAuth2 credential in n8n: Google auth succeeds,
then the browser gets sent to `http://localhost:5778/rest/oauth2-credential/callback`
— `ERR_CONNECTION_REFUSED`, since nothing public is listening there.
Google itself may also reject the initial request with `Error 400:
redirect_uri_mismatch`, since the URI n8n registered with Google was the
localhost one. **Root cause: `WEBHOOK_URL`.** n8n builds every
externally-facing URL it generates — webhooks *and* the OAuth2 callback,
confirmed via `/rest/settings`'s `oidc.loginUrl` changing identically —
from this one env var, and the stack's original default
(`http://localhost:${N8N_PORT}/`) was correct only for the SSH-tunnel-only
setup this was first built for. **Fix: set `WEBHOOK_URL` to the actual
public hostname** (`https://agents.punith.tech/` as of 2026-09-09),
restart n8n (env changes need a restart to take effect, same as any other
service here), and — the other half, easy to miss — **add the new
callback URL to the OAuth client's Authorized redirect URIs in Google
Cloud Console**: `https://agents.punith.tech/rest/oauth2-credential/callback`.
Both sides have to agree on the same URI or Google keeps rejecting it.

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

## 7. Concurrency — how many people can this stack serve at once

- **LiteLLM itself imposes no concurrency limit.** It's a stateless async
  proxy/router — it doesn't do inference, it just forwards each request to
  whichever backend the `model_list` entry points at, so it happily handles
  many simultaneous requests from many people. Whatever limit exists comes
  from the backend behind it, not from LiteLLM.
- **vLLM (`qwen3-235b`, `qwen3-coder-480b`) is built for exactly this** —
  continuous batching serves multiple concurrent requests together rather
  than queueing them one at a time. Several people can hit either model
  through LiteLLM at once; what degrades under load isn't request handling,
  it's available KV cache (see §5.9a) — more concurrent conversations means
  less context headroom per conversation, tunable via `--max-model-len` /
  `--gpu-memory-utilization` in `VLLM_EXTRA_ARGS`/`CODER_EXTRA_ARGS`.
- **Ollama (small fallback models) does not batch the same way.**
  `OLLAMA_NUM_PARALLEL=2` (`00-env.sh`) caps it at 2 concurrent requests per
  loaded model — a 3rd concurrent request queues behind the first two. Fine
  for personal use + light n8n glue traffic, a real bottleneck if several
  people lean on `llama3.2:3b`/`qwen2.5-coder:7b` at the same time. The big
  vLLM models don't have this ceiling.
- **Everyone currently shares one LiteLLM key** (`master_key` in
  `$WORK/apps/litellm/config.yaml`) — no per-person usage tracking or
  budgets. If more than one real person is going to use this, LiteLLM can
  issue separate virtual keys per person (`/key/generate`, or its own UI at
  `http://127.0.0.1:4100/ui`) each with its own rate/budget limits, instead
  of everyone sharing the master key with full access. Not set up yet —
  worth doing before handing the endpoint to anyone else.

## 8. Onboarding prompt for a new session

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
