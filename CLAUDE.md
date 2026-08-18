# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`clauded` is a bash wrapper that runs Claude Code inside a locked-down, per-directory
Docker container (Fedora-based image built from `Dockerfile.claude`). There is no
application code, package manager, build system, or test suite — the entire project
is the `clauded` script plus its supporting Docker/config files:

- `clauded` — the wrapper script; all logic (flag parsing, image build, container
  lifecycle, mounts, lockdown networking) lives here in one file.
- `Dockerfile.claude` — the sandbox image (Fedora 44 + Node/npm, Java 25 via
  Adoptium, `gh` CLI, Claude Code installed globally at a fixed path).
- `entrypoint.sh` — not currently wired into the Dockerfile's `CMD`/`ENTRYPOINT`;
  it exists to symlink the `claude` binary into `$HOME/.local/bin` on a fresh
  tmpfs `$HOME` (the same fix is also applied via `docker exec` in `clauded` after
  boot — see below).
- `egress-allowlist.conf` — Squid allowlist consumed by the `--lockdown` proxy.

## Commands

There is no build/lint/test tooling. To validate changes to `clauded` itself:

```sh
bash -n clauded                        # syntax check
shellcheck clauded                     # if shellcheck is available
./clauded --rebuild                    # force image rebuild + relaunch in this repo
docker build -f Dockerfile.claude -t claude-sandbox:latest .   # build image directly
```

There's no automated test suite — verify behavioral changes by actually running
`clauded` (and its flag combinations) against a scratch directory and inspecting
the resulting container with `docker inspect` / `docker exec`.

## Architecture

### Container lifecycle (all in `clauded`)

1. **Flag parsing** — `clauded`'s own flags (`--no-gh`, `--safe`, `--rebuild`,
   `--lockdown`, `--no-limits`, `--work-root [path]`) are stripped out; everything
   else is forwarded verbatim to `claude` at exec time.
2. **Image build** — `claude-sandbox:latest` is built on first run or `--rebuild`
   (which also does `docker rm -f` on any running container so the new image
   actually gets used, and passes `--no-cache`).
3. **Container naming/reuse** — one container per host directory, named
   `<dirname>-<md5(pwd)[:8]>-sandbox`, so multiple repos get independent, reusable
   sandboxes. With `--work-root`, naming is keyed off the work-root path instead,
   giving one shared container for an entire tree of sibling repos (container
   workdir is set to the caller's path relative to the work root).
4. **Boot** — if no container with that name is running, one is created with
   `docker run -d ... tail -f /dev/null` (kept alive as a daemon; commands are
   `docker exec`'d into it).
5. **Post-boot fixup** — `docker exec` re-creates `~/.local/bin/claude` as a
   symlink every invocation, because `$HOME` is a fresh tmpfs on each container
   boot and Claude Code's self-check expects the binary there.
6. **Exec** — `docker exec -it -w <workdir> <container> claude [--permission-mode auto] <forwarded args>`.
   Default is full-auto (`--permission-mode auto`); `--safe` drops that flag for
   normal permission-prompt behavior.

### Isolation model (why the mounts/flags are what they are)

- `--read-only` root FS + `--tmpfs /tmp` + `--tmpfs $HOME` — nothing persists
  outside explicit mounts; `$HOME` being tmpfs is *why* step 5 above is needed.
- `--cap-drop=ALL` + `--security-opt=no-new-privileges` — no privilege escalation.
- Only `$(pwd)` (or the whole work root, under `--work-root`) is bind-mounted in;
  the rest of the host filesystem is invisible to the container.
- `~/.claude` is bind-mounted **read-write** so the sandbox shares login state and
  writes session history back to the host — but `~/.claude/settings.json`,
  `~/.claude/settings.local.json`, and `~/.claude.json` are then re-mounted
  **read-only on top of that**, specifically to stop a full-auto agent from
  planting a hook that would get host RCE the next time `claude` runs unsandboxed.
  Don't remove those `:ro` overlay mounts without re-reading
  `3e4cdcf security: mount Claude config files read-only to prevent hook poisoning`.
- Resource limits (`--pids-limit`, `--memory`, `--cpus`; overridable via
  `CLAUDED_PIDS_LIMIT`/`CLAUDED_MEMORY`/`CLAUDED_CPUS`, disabled by `--no-limits`)
  exist to contain fork bombs and runaway builds, not to be a general throttle —
  defaults are sized generously for things like parallel `gradlew` builds.

### Lockdown networking (`--lockdown`)

Two extra long-lived Docker resources, created once and shared across *all*
lockdown sandboxes (not per-repo):

- `claude-egress` — a Docker network created with `--internal`, so anything
  attached to it has no NAT route to the real internet at all.
- `claude-egress-proxy` — a single Squid container, dual-homed onto both
  `claude-egress` and the default bridge network. It's the only container with
  an actual internet route, and it enforces `egress-allowlist.conf` on every
  `CONNECT`. It runs in its own container/PID namespace, so a compromised agent
  inside the sandbox cannot kill or tamper with it.

A lockdown sandbox joins only `claude-egress` and gets `HTTPS_PROXY`/`HTTP_PROXY`
pointed at the proxy. Because the network itself has no route out, an agent that
ignores the proxy env vars simply has nowhere to send packets — the allowlist
isn't just policy, it's structurally enforced outside the agent's trust boundary.

To add a new allowed host, edit `egress-allowlist.conf` and recreate the proxy
(`docker rm -f claude-egress-proxy`; it's recreated fresh on the next
`clauded --lockdown`).

## Making changes here

- This script directly shapes a security sandbox boundary — when touching mount
  flags, cap drops, or the lockdown network/proxy setup, preserve the *intent*
  documented above, not just the current syntax. Re-derive from README.md's
  "Security model" table if unsure what a given mount/flag is protecting against.
- Container/network/proxy names (`claude-egress`, `claude-egress-proxy`, the
  `<dirname>-<hash>-sandbox` pattern) are relied on by the cleanup instructions in
  README.md — keep them in sync if renamed.
