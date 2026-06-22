# docker-dev-sandbox

A wrapper (`clauded`) for running Claude Code inside an isolated Docker container.
Run it from any repo and get a fully-autonomous Claude instance that's sandboxed
away from the rest of your host machine.

## What it does

`clauded` boots a per-directory Docker container with:

- **Full-auto by default** — Claude runs with `--dangerously-skip-permissions` so
  it never stops to ask for approval. The container is the guardrail.
- **Only the current repo mounted** — the host home is invisible inside the box.
- **Read-only root filesystem** — Claude can only write to `/workspace` (your repo),
  `~/.claude` (shared with the host), and `/tmp`.
- **Hard capability drop** — `--cap-drop=ALL` + `no-new-privileges`.
- **Login reuse** — your host `~/.claude` and `~/.claude.json` are bind-mounted
  read-write so the sandbox reuses your existing Claude login and writes sessions
  and history back to the host.
- **One container per working directory** — named `<dirname>-<dirhash>-sandbox`,
  so you can have independent sandboxes for multiple repos at once.

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
clauded [--no-gh] [--safe] [--rebuild] [claude args...]
```

| Flag        | Meaning |
|-------------|---------|
| _(none)_    | Full-auto Claude inside the sandbox |
| `--safe`    | Normal Claude with permission prompts (no `--dangerously-skip-permissions`) |
| `--no-gh`   | Skip GitHub CLI token injection |
| `--rebuild` | Force a rebuild of the Docker image before starting |

Any additional arguments are passed through to `claude` unchanged.

```sh
clauded                        # full-auto, with gh token
clauded --safe                 # interactive/prompted mode
clauded --no-gh                # skip gh token
clauded --rebuild              # rebuild image then launch
clauded --no-gh --safe "help"  # flags compose freely
```

## Security model

| Property | Mechanism |
|---|---|
| No host filesystem access | Only `$(pwd)` mounted at `/workspace` |
| No privilege escalation | `--cap-drop=ALL` + `no-new-privileges` |
| No writes outside mounts | `--read-only` root FS |
| Scratch space | `tmpfs` at `/tmp` and `$HOME` (ephemeral) |
| No host network config leakage | Only GH_TOKEN injected explicitly |

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

The old `claude-fortress:local` image from a previous iteration can be removed:

```sh
docker rmi claude-fortress:local
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
