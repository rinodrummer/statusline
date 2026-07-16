#!/bin/bash
#
# Standalone installer for the Claude Code statusline.
#
# Deploys three things into the Claude Code config dir (default ~/.claude):
#   statusline-command.sh    -> $CONFIG_DIR/statusline-command.sh          (the renderer)
#   statusline-settings.js   -> $CONFIG_DIR/scripts/claude/statusline-settings.js
#   commands/*.md            -> $CONFIG_DIR/commands/                      (slash commands)
#
# ...then points settings.json's statusLine.command at the deployed renderer.
#
# The helper's deployed path is not a free choice: the slash commands hardcode
# `node ~/.claude/scripts/claude/statusline-settings.js`, so it has to land there.
#
# Additive and idempotent by construction: it writes only the paths above and the
# single statusLine key, deletes nothing, and a second run produces a byte-identical
# tree. settings.json is patched through jq (read -> modify -> atomic mv), never
# rewritten wholesale, so unrelated keys survive untouched.
#
# Dotfiles users: this installer is NOT for you. The dotfiles repo consumes this
# repo as a submodule and deploys these files with its own installer.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR="$HOME/.claude"
INSTALL_MODE="copy"
FORCE=false

usage() {
  cat <<'MSG'
Usage: ./install.sh [--mode=copy|symlink] [--config-dir <path>] [--force]

  --mode=copy      Copy the files (default). Standalone: the install keeps
                   working if this clone moves or is deleted.
  --mode=symlink   Link the files back to this clone, so a `git pull` updates
                   the installed statusline. Requires the clone to stay put.

  --config-dir <path>  Claude Code config dir to install into.
                       Default: ~/.claude

  --force          Replace an existing, unrelated statusLine in settings.json.
                   Without it, a statusline you already have is left alone and
                   only the wiring step is skipped.

Copy is the default because a colleague's clone is likely to move; symlink is
what you want if you track this repo and expect pulls to take effect.
MSG
}

# Expand a leading `~/` by hand. The shell only expands tilde in a real
# assignment, so `--config-dir=~/foo` arrives here as the literal string "~/foo"
# and would otherwise create a directory actually named "~" in the cwd. The
# two-token form (`--config-dir ~/foo`) is expanded by the shell before we see it;
# this makes the two spellings agree.
expand_tilde() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- Arguments ----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      [ $# -ge 2 ] || { echo "Error: --mode requires a value (copy|symlink)" >&2; exit 1; }
      INSTALL_MODE="$2"
      shift
      ;;
    --mode=*)
      INSTALL_MODE="${1#--mode=}"
      ;;
    --config-dir)
      [ $# -ge 2 ] || { echo "Error: --config-dir requires a path" >&2; exit 1; }
      CONFIG_DIR="$(expand_tilde "$2")"
      shift
      ;;
    --config-dir=*)
      CONFIG_DIR="$(expand_tilde "${1#--config-dir=}")"
      ;;
    --force)
      FORCE=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (use --help for usage)" >&2
      exit 1
      ;;
  esac
  shift
done

# Fold case by hand: macOS ships bash 3.2, which has no ${var,,}.
INSTALL_MODE="$(printf '%s' "$INSTALL_MODE" | tr '[:upper:]' '[:lower:]')"

case "$INSTALL_MODE" in
  copy|symlink) ;;
  *)
    echo "Error: invalid mode '$INSTALL_MODE' (use 'copy' or 'symlink')" >&2
    exit 1
    ;;
esac

if [ -z "$CONFIG_DIR" ]; then
  echo "Error: --config-dir cannot be empty" >&2
  exit 1
fi

# --- Preflight ----------------------------------------------------------------
# jq is hard: the renderer parses its session JSON with it, so a statusline
# without jq is not a degraded statusline, it is no statusline. git and node are
# soft: each is needed by one optional piece, and the rest still renders without.
if ! command -v jq >/dev/null 2>&1; then
  cat >&2 <<'MSG'
Error: 'jq' not found — required by the statusline renderer, not just this installer.
Install it with one of:
  sudo apt install -y jq      # Debian/Ubuntu/WSL
  brew install jq             # macOS
MSG
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Warning: 'git' not found — the line-2 git group (repo, branch, status) will not render."
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Warning: 'node' not found — the /statusline-options slash command and the"
  echo "         statusline-settings.js helper will not run. The statusline itself"
  echo "         still renders, using its built-in defaults."
fi

# A plain file here would make the mkdir fail with a bare errno; say what is wrong.
if [ -e "$CONFIG_DIR" ] && [ ! -d "$CONFIG_DIR" ]; then
  echo "Error: --config-dir path exists but is not a directory: $CONFIG_DIR" >&2
  exit 1
fi

# Resolve CONFIG_DIR to an absolute path. Done by cd+pwd rather than realpath:
# macOS has no realpath before coreutils, and the dir exists by this point anyway.
mkdir -p "$CONFIG_DIR"
CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"

echo "Install mode: $INSTALL_MODE"
echo "Config dir:   $CONFIG_DIR"

# --- Deploy -------------------------------------------------------------------
# Deploy one file in the selected mode. Returns non-zero when it skips, so every
# call site is `if install_file ...; then`: a bare call would take the whole
# script down under `set -e` (which is not what "skipping" promises), and it also
# keeps a "Deployed" line from being printed for a file that was not.
#
# The `rm -f` before copying is load-bearing: if a previous symlink-mode run left
# dest pointing at src, `cp -f src dest` would either write through the link into
# this repo or abort with "same file". Removing it first makes a mode switch a
# plain overwrite in both directions (`ln -sfn` already replaces a regular file).
install_file() {
  local src="$1"
  local dest="$2"

  if [ ! -e "$src" ]; then
    echo "Warning: source file not found, skipping: $src"
    return 1
  fi

  # A directory at dest would make `ln -sfn` quietly link *inside* it and `cp`
  # fail with a bare errno. Neither is ours to remove — say what is wrong instead.
  if [ -d "$dest" ] && [ ! -L "$dest" ]; then
    echo "Warning: $dest is a directory, skipping. Move it aside and re-run."
    return 1
  fi

  mkdir -p "$(dirname "$dest")"

  if [ "$INSTALL_MODE" = "copy" ]; then
    rm -f "$dest"
    cp -f "$src" "$dest"
  else
    ln -sfn "$src" "$dest"
  fi
}

if install_file "$REPO_DIR/statusline-command.sh" "$CONFIG_DIR/statusline-command.sh"; then
  echo "Deployed renderer: $CONFIG_DIR/statusline-command.sh"
fi

# The renderer is invoked as `bash <path>`, so its exec bit is not strictly
# required — set it anyway so it stays runnable by hand, and because copy mode
# does not always preserve it across filesystems (e.g. a mounted share).
chmod +x "$CONFIG_DIR/statusline-command.sh" 2>/dev/null || true

if install_file "$REPO_DIR/statusline-settings.js" "$CONFIG_DIR/scripts/claude/statusline-settings.js"; then
  echo "Deployed settings helper: $CONFIG_DIR/scripts/claude/statusline-settings.js"
fi

# Slash commands. Deployed verbatim: they hardcode
# `node ~/.claude/scripts/claude/statusline-settings.js`, which means that under a
# non-default --config-dir the commands still point at ~/.claude. Left as-is on
# purpose — patching them would rewrite this repo's own files in symlink mode.
# See the README's "Not using ~/.claude?" section for the consequence.
mkdir -p "$CONFIG_DIR/commands"
commands_found=false
for cmd_file in "$REPO_DIR"/commands/*.md; do
  [ -e "$cmd_file" ] || continue
  if install_file "$cmd_file" "$CONFIG_DIR/commands/$(basename "$cmd_file")"; then
    commands_found=true
  fi
done
if [ "$commands_found" = true ]; then
  echo "Deployed slash commands: $CONFIG_DIR/commands/"
else
  echo "Warning: no slash commands found in $REPO_DIR/commands/, skipping."
fi

# --- Wire the statusline into settings.json -----------------------------------
# Read-modify-write through jq so every unrelated key survives. The temp file +
# mv keeps it atomic: a failed jq leaves the original settings.json untouched
# rather than truncated, which matters because this is the user's live config.
settings_file="$CONFIG_DIR/settings.json"

# statusLine.command is a *shell command string*, not just a JSON value: Claude
# Code hands it to a shell. So the path needs shell-quoting inside the string, or
# a --config-dir containing a space produces `bash /two words/statusline-command.sh`,
# which the shell splits into a wrong path and a stray argument — the install would
# report success while the statusline silently never rendered. printf %q is bash
# 3.2-safe, and leaves an ordinary path completely untouched, so the common case
# stays byte-identical across runs.
status_command="bash $(printf '%q' "$CONFIG_DIR/statusline-command.sh")"

if [ -e "$settings_file" ] && [ ! -f "$settings_file" ]; then
  echo "Error: $settings_file exists but is not a regular file." >&2
  echo "       Move it aside and re-run." >&2
  exit 1
fi

if [ ! -f "$settings_file" ]; then
  echo '{}' > "$settings_file"
  echo "Created $settings_file"
fi

if ! jq -e . "$settings_file" >/dev/null 2>&1; then
  echo "Error: $settings_file is not valid JSON. Fix or move it, then re-run." >&2
  echo "       Refusing to touch it — overwriting a broken config would lose your settings." >&2
  exit 1
fi

# Never take someone else's statusline without asking. A stranger running this
# script may already have one (oh-my-posh, a hand-rolled script), and silently
# replacing it is the same class of harm as deleting their files: "additive" has
# to cover their config, not just the filesystem.
#
# Ours is anything invoking a statusline-command.sh — which matches this install
# and also the `~`-spelled or --config-dir-carrying variants of it, so a re-run
# still updates a config we wrote earlier rather than refusing it. Anything else
# is theirs and is left alone unless --force says otherwise.
existing_status_command="$(jq -r '.statusLine.command // empty' "$settings_file")"
wire_statusline=true
case "$existing_status_command" in
  "") ;;                          # nothing there: ours to write
  *statusline-command.sh*) ;;     # already this statusline: update in place
  *)
    if [ "$FORCE" = true ]; then
      echo "Replacing existing statusLine (--force): $existing_status_command"
    else
      wire_statusline=false
      echo ""
      echo "Warning: $settings_file already has a statusLine, left untouched:"
      echo "           $existing_status_command"
      echo "         Everything else is installed; only the wiring was skipped."
      echo "         To use this statusline instead, re-run with --force, or set"
      echo "         statusLine.command to:"
      echo "           $status_command"
    fi
    ;;
esac

if [ "$wire_statusline" = true ]; then
  # The temp file lives in $CONFIG_DIR, not $TMPDIR, so the mv is a rename within
  # one filesystem and therefore atomic. Across filesystems mv degrades to
  # copy-then-unlink, which can leave a half-written settings.json behind.
  settings_tmp="$(mktemp "$CONFIG_DIR/.settings.json.XXXXXX")"
  # Assign the whole object rather than merging into it: a pre-existing statusLine
  # of a different shape would otherwise keep its stale sibling keys next to ours.
  if jq --arg cmd "$status_command" \
       '.statusLine = {type: "command", command: $cmd}' \
       "$settings_file" > "$settings_tmp"; then
    mv "$settings_tmp" "$settings_file"
    echo "Wired statusLine.command -> $status_command"
  else
    rm -f "$settings_tmp"
    echo "Error: failed to patch $settings_file" >&2
    exit 1
  fi
fi

echo ""
if [ "$wire_statusline" = true ]; then
  echo "Done. Start (or restart) Claude Code to see the statusline."
else
  echo "Done, except the statusLine wiring above."
fi
if command -v node >/dev/null 2>&1; then
  echo "Configure it with /statusline-options, or:"
  echo "  node $CONFIG_DIR/scripts/claude/statusline-settings.js options"
fi
