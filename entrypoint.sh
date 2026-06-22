#!/usr/bin/env bash
# Claude Code checks for itself at $HOME/.local/bin/claude on startup.
# HOME is a fresh tmpfs each run, so we symlink the global install into place.
if [ -n "$HOME" ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v claude)" "$HOME/.local/bin/claude"
fi
exec "$@"
