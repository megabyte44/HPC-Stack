# BOOTSTRAP — total loss recovery

Follow this if `~/hpc-stack` itself is gone (deleted home dir, new account,
new cluster, whatever) — not just a `$WORK` wipe. Assume you have nothing but:
a terminal, SSH access to `sastra-master-node`, and access to your GitHub
account (`megabyte44/HPC-Stack`).

This is written so you can follow it with **no AI assistance** — every
command is literal, nothing requires you to remember why. If you *do* still
have a working `~/hpc-stack/`, use `restore-all.sh` instead (see
`KNOWLEDGE.md` §4) — this doc is specifically for when that directory itself
is gone.

---

## 0. What you need in hand before you start

- SSH access to `sastra-master-node` (a username + key/password that gets
  you in).
- Your GitHub login, to reach `https://github.com/megabyte44/HPC-Stack`
  (only needed if the repo is private and `git clone` prompts for auth).
- The 5 secret values, from wherever you stashed them per §6 below
  (password manager, second machine, printed sheet — anywhere that isn't
  *only* `~/hpc-stack` itself, since that's exactly what you just lost).
  If you never stashed them, read §5.2 — most are recoverable a different
  way, one is not.

If you're missing the SSH access or the GitHub access, stop — there is no
command-line path around either of those, you need whoever administers the
cluster / your GitHub account to restore access first.

---

## 1. Get the scripts back

```bash
ssh <your-username>@sastra-master-node
git clone https://github.com/megabyte44/HPC-Stack.git ~/hpc-stack
chmod +x ~/hpc-stack/*.sh
```

If `git` isn't installed on the master node, ask cluster support — there is
no sudo here to install it yourself. (If it's present but old, this still
works; nothing here needs a recent git.)

Confirm you got everything:

```bash
ls ~/hpc-stack
# expect: 00-env.sh 10-toolchain.sh 20-apps.sh svc.sh doctor.sh
#         restore-all.sh fix-webui-toolcalling.sh keepalive.sh
#         bashrc-snippet.sh laptop-ssh-config.example README.md
#         KNOWLEDGE.md BOOTSTRAP.md .gitignore
```

Note what's **missing** on purpose: the 5 dotfiles below. `.gitignore`
excludes them deliberately (see its own comment) — GitHub never had them,
so `git clone` cannot bring them back. That's §2.

---

## 2. Recreate the secrets

Five files live in `~/hpc-stack/` but were never in git:
`.hf_token`, `.litellm_master_key`, `.cloudflare_tunnel_token`,
`.n8n_owner_password`, `.webui_new_password`.

They fall into two very different categories — know which is which before
you assume anything is "lost forever":

### 2.1 Auto-regenerate — do nothing, the scripts handle it

- **`.litellm_master_key`** — if missing, `20-apps.sh` generates a new
  random one and writes it here itself. No action needed. The only
  consequence of it being new is that any *previously configured* external
  client (a VS Code settings.json, a saved curl script) that hardcoded the
  old key will need updating with the new one — check
  `cat ~/hpc-stack/.litellm_master_key` after `20-apps.sh` runs and update
  those clients.
- **Open-WebUI's session secret** (`$DATA_DIR/open-webui/.secret`, lives
  under `$WORK` not `$HOME`, listed here for completeness) — `20-apps.sh`
  generates this too if missing. No action needed; it only means existing
  browser sessions get invalidated, not a real loss.

### 2.2 Must be recreated by hand — from an external source, not from git

- **`.hf_token`** — a HuggingFace access token. Get a new one at
  `https://huggingface.co/settings/tokens` (log in with your HF account,
  "New token", read-only is enough), then:
  ```bash
  echo '<paste the token>' > ~/hpc-stack/.hf_token
  chmod 600 ~/hpc-stack/.hf_token
  ```
- **`.cloudflare_tunnel_token`** — from the Cloudflare Zero Trust
  dashboard → **Networks → Tunnels** → your existing tunnel → **Configure**
  → copy its token (or create a new tunnel if the old one is gone too —
  either way, the token lives in your Cloudflare account, not on this
  cluster, so it is *not* actually lost, just needs re-fetching):
  ```bash
  echo '<paste the tunnel token>' > ~/hpc-stack/.cloudflare_tunnel_token
  chmod 600 ~/hpc-stack/.cloudflare_tunnel_token
  ```
  If you also lost track of which Public Hostname routes you'd configured,
  they're visible in that same dashboard page — re-check them against the
  exposure notes in `KNOWLEDGE.md` §3 before you re-enable anything.

### 2.3 Genuinely irrecoverable if not backed up elsewhere

- **`.n8n_owner_password`** and **`.webui_new_password`** — these two files
  are *not* read by any script. They only ever existed as your own written
  record of the passwords you typed into each app's signup form. If you
  don't have them backed up separately, the passwords themselves are gone
  — but the *accounts* are recoverable because you're about to rebuild both
  apps' databases from scratch anyway (§4 below starts them empty). Just
  sign up again with a new password when you first open each app's URL,
  then write the new password down somewhere durable (see §6):
  ```bash
  echo '<new n8n owner password you just chose>' > ~/hpc-stack/.n8n_owner_password
  echo '<new open-webui admin password you just chose>' > ~/hpc-stack/.webui_new_password
  chmod 600 ~/hpc-stack/.n8n_owner_password ~/hpc-stack/.webui_new_password
  ```

---

## 3. Wire up the shell

```bash
cat ~/hpc-stack/bashrc-snippet.sh >> ~/.bashrc
source ~/.bashrc
```

Confirm: your prompt should now show `[master]` or `[gpu]` in color, and
`svc`/`doctor`/`gpu` should be usable as bare commands.

---

## 4. Rebuild the toolchain and apps on the GPU node

```bash
ssh dgx-node1
bash ~/hpc-stack/10-toolchain.sh     # ollama, node, uv (~2 min)
bash ~/hpc-stack/20-apps.sh          # open-webui, n8n, litellm (~10 min, ~6 GB)
```

Or skip straight to the combined version, which also starts base services
and pulls the two small fallback models in one go:

```bash
bash ~/hpc-stack/restore-all.sh
```

Add `--comfyui` to also reinstall ComfyUI, and/or `--models` to also
install vLLM and start the two big models — **check `nvidia-smi` first**
if you use `--models`, the GPU numbers baked into the script are last
known-good, not guaranteed free right now:

```bash
nvidia-smi
export VLLM_GPUS=0,3 CODER_GPUS=4,5,6,7   # only if different from defaults
bash ~/hpc-stack/restore-all.sh --models --comfyui
```

`--models` re-downloads roughly 717GB of model weights — only run it when
you actually want that traffic and time cost right now; the base stack
(chat with small models, n8n, litellm) works without it.

---

## 5. Sign back in and finish the manual account steps

1. From your laptop (see §7 for the tunnel), open
   `http://localhost:8180` (Open-WebUI, offset port) and
   `http://localhost:5778` (n8n) — **in that order, right away**, before
   anyone else on the cluster can. Whoever loads each UI first claims the
   admin/owner account; `ENABLE_SIGNUP=false` only blocks people *after*
   that first account exists.
2. Sign up on both with the passwords you just wrote down in §2.3.
3. Re-apply the Open-WebUI tool-calling fix now that the account exists:
   ```bash
   bash ~/hpc-stack/fix-webui-toolcalling.sh
   ```
   (`restore-all.sh` already tried this once and skipped it, since there
   was no account yet at that point — this is the expected sequence, not
   a failure.)

---

## 6. Verify

```bash
bash ~/hpc-stack/doctor.sh
```

Read every section. `HOME LEAK CHECK` and `ENVIRONMENT` should be all
green; `ENDPOINTS` should show whichever services you started as
responding; `EXPOSURE` should match what you actually intend to be public.

---

## 7. Reconnect from your laptop

On your laptop (not the cluster), merge `~/hpc-stack/laptop-ssh-config.example`
into `~/.ssh/config`, filling in the real hostname/username, then:

```bash
ssh -N gpu-tunnel
```

Leave that running in its own terminal. Open `http://localhost:8180` for
chat, `http://localhost:5778` for n8n.

---

## 8. Do this now, before you ever need this document again

The single biggest gap in this whole recovery plan is that the 5 secret
files in §2 exist **only** on this cluster's NFS home. NFS is far more
durable than `$WORK` (node-local `/tmp`), but it is still one location. If
it is ever wiped, deleted, or the account is lost, §2.3's two passwords are
gone for good and §2.2's two tokens need a trip back to their respective
dashboards.

Right now, from a shell on the cluster, copy each of these five files
somewhere durable that isn't this cluster and isn't GitHub (a password
manager entry, an encrypted note — anywhere under *your* control, off this
box):

```bash
cat ~/hpc-stack/.hf_token
cat ~/hpc-stack/.litellm_master_key
cat ~/hpc-stack/.cloudflare_tunnel_token
cat ~/hpc-stack/.n8n_owner_password
cat ~/hpc-stack/.webui_new_password
```

Paste each value into your password manager by hand, labeled clearly
(e.g. "HPC stack — HF token"). Do this yourself, interactively — it's
exactly the kind of value that shouldn't be pasted into a chat log,
ticket, or shared doc, AI-assisted or not.

Re-do this any time you rotate a token or change a password. That's it —
with this doc, the GitHub remote, and those five values saved somewhere
independent, the entire stack is reconstructible from nothing.
