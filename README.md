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
