#!/usr/bin/env bash
# Record the README's demo media with vhs (https://github.com/charmbracelet/vhs),
# running a real `claude` (haiku) inside Neovim in a made-up project.
#
# Usage: demo/render.sh [shot ...]     (default: every tape in demo/tapes)
#
# Environment (all optional except where a default does not exist):
#   DEMO_ROOT       where the project and the output go   (default /tmp/demo)
#   DEMO_OUT        where the GIFs and PNGs go            (default $DEMO_ROOT/out)
#   DEMO_PLUGINS    a directory holding plugin checkouts  (default lazy.nvim's)
#   DEMO_UNIFIED    papricasix/unified.nvim checkout      (default $DEMO_PLUGINS/unified.nvim)
#   DEMO_SNACKS     folke/snacks.nvim checkout            (default $DEMO_PLUGINS/snacks.nvim)
#   DEMO_COLORSCHEME_DIR / DEMO_COLORSCHEME               (default tokyonight.nvim / tokyonight-moon)
#
# Each shot gets a fresh project; a tape with a `# seed` line also gets a seeded
# history (demo/seed.sh). The project's transcripts are removed from the
# Claude Code store before every shot, so nothing from an earlier run shows.
# Recording costs real (haiku) usage on the account `claude` is logged in to.

set -euo pipefail

demo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run in a clean environment: a parent Claude Code session's CLAUDE* variables
# would make the recorded CLI attach to that session's editor or save no transcript.
# The XDG directories and CLAUDE_CONFIG_DIR are passed through untouched: the CLI
# keeps its installed versions under XDG_DATA_HOME, and a different one makes it
# install itself there and repoint the user's `claude` launcher at the copy.
if [[ -z "${DEMO_CLEAN:-}" ]]; then
  plugins="${DEMO_PLUGINS:-${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy}"
  root="${DEMO_ROOT:-/tmp/demo}"
  keep=()
  for var in XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME CLAUDE_CONFIG_DIR; do
    if [[ -n "${!var:-}" ]]; then
      keep+=("$var=${!var}")
    fi
  done
  exec env -i \
    DEMO_CLEAN=1 HOME="$HOME" USER="$USER" PATH="$PATH" TERM=xterm-256color LANG="${LANG:-en_US.UTF-8}" \
    SHELL=/bin/bash ${keep[@]+"${keep[@]}"} \
    DEMO_ROOT="$root" DEMO_OUT="${DEMO_OUT:-$root/out}" \
    DEMO_UNIFIED="${DEMO_UNIFIED:-$plugins/unified.nvim}" \
    DEMO_SNACKS="${DEMO_SNACKS:-$plugins/snacks.nvim}" \
    DEMO_COLORSCHEME_DIR="${DEMO_COLORSCHEME_DIR:-$plugins/tokyonight.nvim}" \
    DEMO_COLORSCHEME="${DEMO_COLORSCHEME:-tokyonight-moon}" \
    "$0" "$@"
fi

for tool in vhs claude nvim git; do
  command -v "$tool" >/dev/null || {
    echo "render.sh: $tool not found on PATH" >&2
    exit 1
  }
done
[[ -f "$DEMO_UNIFIED/lua/unified/init.lua" ]] || {
  echo "render.sh: unified.nvim not found at $DEMO_UNIFIED (set DEMO_UNIFIED)" >&2
  exit 1
}

project="$DEMO_ROOT/acme-shop"
export DEMO_PROJECT="$project" DEMO_INIT="$demo/init.lua"

# The shell inside a recording sees only the tools a shot needs. Claude Code
# offers to install an LSP plugin, in a dialog, the first time it touches a file
# whose language server binary is on PATH; without one there is no dialog.
mkdir -p "$DEMO_ROOT/bin"
for tool in claude nvim git; do
  ln -sf "$(command -v "$tool")" "$DEMO_ROOT/bin/$tool"
done
export DEMO_PATH="$DEMO_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Neovim keeps its state (agents flags and checkpoints, caches) under its own
# name, away from the user's. NVIM_APPNAME moves only Neovim's directories.
export NVIM_APPNAME=claude-agents-demo
nvim_dirs=("${XDG_CACHE_HOME:-$HOME/.cache}/$NVIM_APPNAME" "${XDG_STATE_HOME:-$HOME/.local/state}/$NVIM_APPNAME")
mkdir -p "$DEMO_OUT"

# Remove the project's directory in the Claude Code store (the CLI's slug rule:
# every non-alphanumeric character of the path becomes `-`). Refuses anything
# that does not end in the project's own name, so a failed lookup can never
# widen into the whole store.
forget_transcripts() {
  local real slug
  real="$(cd "$project" && pwd -P)" || return 1
  slug="${real//[^a-zA-Z0-9]/-}"
  if [[ -z "$real" || "$slug" != *-acme-shop ]]; then
    echo "render.sh: refusing to remove store dir for '$real'" >&2
    return 1
  fi
  rm -rf "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug"
}

shots=("$@")
if [[ ${#shots[@]} -eq 0 ]]; then
  for tape in "$demo"/tapes/*.tape; do
    name="$(basename "$tape" .tape)"
    [[ "$name" == trust ]] || shots+=("$name")
  done
fi

# Claude Code asks once per folder whether to trust it; answer before recording.
# This records the demo project as trusted in the CLI's own config (~/.claude.json).
"$demo/sandbox.sh" "$project"
trap forget_transcripts EXIT
(cd "$DEMO_OUT" && vhs "$demo/tapes/trust.tape" >/dev/null && rm -f trust.gif)
forget_transcripts

for shot in "${shots[@]}"; do
  tape="$demo/tapes/$shot.tape"
  [[ -f "$tape" ]] || {
    echo "render.sh: no tape $tape" >&2
    exit 1
  }

  echo "==> $shot"
  "$demo/sandbox.sh" "$project"
  forget_transcripts
  rm -rf "${nvim_dirs[@]}"
  if grep -q '^# seed' "$tape"; then
    # The demo PATH here too: the seed's interactive run reads Python files, and
    # an LSP dialog it leaves unanswered counts against the user's own config.
    PATH="$DEMO_PATH" "$demo/seed.sh" "$project"
  fi
  (cd "$DEMO_OUT" && vhs "$tape")
done

echo "Output in $DEMO_OUT"
