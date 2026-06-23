# docker-dev-sandbox

A wrapper (`clauded`) for running Claude Code inside an isolated Docker container.
Run it from any repo and get a fully-autonomous Claude instance that's sandboxed
away from the rest of your host machine.

## What it does

`clauded` boots a per-directory Docker container with:

- **Full-auto by default** — Claude runs with `--permission-mode auto` so
  it never stops to ask for approval. The container is the guardrail.
- **Only the current repo mounted** — the host home is invisible inside the box.
- **Read-only root filesystem** — Claude can only write to `/workspace` (your repo),
  `~/.claude` (shared with the host), and `/tmp`.
- **Hard capability drop** — `--cap-drop=ALL` + `no-new-privileges`.
- **Resource limits** — process cap, memory cap, and CPU quota prevent fork bombs
  and resource exhaustion. See [Resource limits](#resource-limits).
- **Login reuse** — your host `~/.claude` and `~/.claude.json` are bind-mounted
  read-write so the sandbox reuses your existing Claude login and writes sessions
  and history back to the host.
- **One container per working directory** — named `<dirname>-<dirhash>-sandbox`,
  so you can have independent sandboxes for multiple repos at once.
- **Optional lockdown mode** — `--lockdown` cuts all direct internet access and
  routes egress through a shared allowlist proxy. See [Lockdown mode](#lockdown-mode).

### Tradeoff to know

Because `~/.claude` is shared read-write, a full-auto Claude inside the box *can*
modify your host Claude config and history. This is intentional (no re-login), but
it means the sandbox isn't fully isolated from your Claude state.

## Setup

### 1. Clone the repo

```sh
git clone <repo-url> ~/work/docker-dev-sandbox
```

### 2. Symlink `clauded` onto your PATH

```sh
ln -s ~/work/docker-dev-sandbox/clauded ~/tools/bin/clauded  # or wherever
```

### 3. Run it

The image is **built automatically** on the first run:

```sh
cd ~/my-project
clauded
```

That's it. Docker must be running; `gh auth login` must have been done on the host
(unless you use `--no-gh`).

## Usage

```
clauded [--no-gh] [--safe] [--rebuild] [--lockdown] [claude args...]
```

| Flag          | Meaning |
|---------------|---------|
| _(none)_      | Auto-mode Claude inside the sandbox (`--permission-mode auto`) |
| `--safe`      | Normal Claude with permission prompts |
| `--no-gh`     | Skip GitHub CLI token injection |
| `--rebuild`   | Force a rebuild of the Docker image before starting |
| `--lockdown`  | Restrict egress to an allowlist via a shared proxy |

Any additional arguments are passed through to `claude` unchanged.

```sh
clauded                          # full-auto, with gh token
clauded --safe                   # interactive/prompted mode
clauded --no-gh                  # skip gh token
clauded --rebuild                # rebuild image then launch
clauded --lockdown               # strict egress filtering
clauded --lockdown --safe        # lockdown + manual permission prompts
clauded --no-gh --safe "help"    # flags compose freely
```

## Resource limits

By default every sandbox runs with these cgroup limits:

| Limit | Default | Override |
|-------|---------|----------|
| Process/thread cap | 4096 | `CLAUDED_PIDS_LIMIT=N` |
| Memory | 8 GB | `CLAUDED_MEMORY=Ng` |
| CPU | 8 cores | `CLAUDED_CPUS=N` |

The pids limit is high enough for a parallel `./gradlew build` (Gradle daemon +
worker processes + forked test JVMs — threads count too). A fork bomb hits any
limit instantly; legitimate builds rarely exceed a few thousand tasks.

Swap is enabled at Docker's default of 2× `--memory` (so 16 GB with an 8 GB
memory cap). This gives spiky builds headroom to avoid OOM kills while still
bounding total memory use.

Override for a memory-hungry or CPU-heavy project:

```sh
CLAUDED_MEMORY=16g CLAUDED_CPUS=8 clauded
```

## Lockdown mode

`--lockdown` adds hard network containment on top of the default sandbox.

```sh
clauded --lockdown
```

### How it works

Without `--lockdown`, containers have normal internet access. With it:

1. A **private internal Docker network** (`claude-egress`) is created with
   `--internal` — containers on it have no NAT route to the internet at all.
2. A **single shared Squid proxy** (`claude-egress-proxy`) starts once and is reused
   by every lockdown sandbox. It's dual-homed: connected to `claude-egress` (visible
   to sandboxes) and to the default bridge (real internet). It is the only egress path.
3. The sandbox joins `claude-egress` and gets `HTTPS_PROXY`/`HTTP_PROXY` pointing at
   the proxy.

Because the network is `--internal`, an agent that ignores the proxy env vars still
has **nowhere to send packets** — there is no route. The proxy enforces the allowlist
on every `CONNECT`. The control mechanism is outside the agent's trust boundary: in a
separate container with its own PID namespace, so the agent can't kill it.

### Allowlist

The allowed domains are in `egress-allowlist.conf` in this repo (mounted read-only
into the proxy). Current list:

- `*.anthropic.com` — Claude API (required)
- `github.com`, `api.github.com`, … — git + `gh` CLI
- `registry.npmjs.org` — npm
- `repo1.maven.org`, `*.gradle.org`, … — Maven/Gradle builds
- `packages.adoptium.net` — Temurin JDK
- `pypi.org`, `files.pythonhosted.org` — pip

Add entries to `egress-allowlist.conf` and restart the proxy when a legitimate tool
needs a new host:

```sh
docker rm -f claude-egress-proxy   # next clauded --lockdown restart it fresh
```

### Claude web search in lockdown mode

Claude's web search and web fetch run **server-side at Anthropic**, not from inside
the container. The container only needs to reach `api.anthropic.com` to issue those
requests. Web search works normally under `--lockdown`.

## Security model

| Property | Mechanism |
|---|---|
| No host filesystem access | Only `$(pwd)` mounted at `/workspace` |
| No privilege escalation | `--cap-drop=ALL` + `no-new-privileges` |
| No writes outside mounts | `--read-only` root FS |
| Scratch space | `tmpfs` at `/tmp` and `$HOME` (ephemeral) |
| Resource exhaustion / fork bomb | `--pids-limit`, `--memory`, `--cpus` |
| Network egress (opt-in) | `--lockdown`: internal network + allowlist proxy |

## Cleaning up

Remove a stopped sandbox container for the current directory:

```sh
DIR_NAME=$(basename "$(pwd)")
DIR_HASH=$(echo -n "$(pwd)" | md5sum | cut -c 1-8)
docker rm "${DIR_NAME}-${DIR_HASH}-sandbox"
```

Remove all sandbox containers at once:

```sh
docker ps -aq --filter "name=-sandbox" | xargs docker rm
```

Remove the lockdown proxy and network:

```sh
docker rm -f claude-egress-proxy
docker network rm claude-egress
```

## Rebuilding the image

The image is rebuilt automatically when it doesn't exist, or on demand:

```sh
clauded --rebuild
```

Or manually:

```sh
docker build -f Dockerfile.claude -t claude-sandbox:latest .
```
