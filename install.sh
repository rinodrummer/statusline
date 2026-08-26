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

# --- Platform -----------------------------------------------------------------
# "Windows bash" means a POSIX emulation layer hosted on Windows — Git Bash and
# MSYS2 (MINGW*/MSYS*) or Cygwin — where Claude Code itself is the *native*
# Windows build. That combination changes exactly one thing that matters here:
# who runs statusLine.command, and in which path syntax. See the wiring section.
#
# WSL is deliberately NOT this case. There uname says Linux, Claude Code and the
# shell agree on POSIX paths, and the existing spelling is already correct.
IS_WINDOWS_BASH=false
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS_BASH=true ;;
esac

# --- Preflight ----------------------------------------------------------------
# jq is hard: the renderer parses its session JSON with it, so a statusline
# without jq is not a degraded statusline, it is no statusline. git and node are
# soft: each is needed by one optional piece, and the rest still renders without.
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' not found — required by the statusline renderer, not just this installer." >&2
  echo "Install it with one of:" >&2
  if [ "$IS_WINDOWS_BASH" = true ]; then
    # Git Bash ships no package manager, and the three Windows ones all install a
    # jq.exe that lands on the PATH this shell inherits. Listing apt/brew here
    # instead would be the whole reason a Git Bash user gives up at this line.
    cat >&2 <<'MSG'
  winget install jqlang.jq    # Windows (built in on Win 10/11)
  scoop install jq            # Windows, if you use Scoop
  choco install jq            # Windows, if you use Chocolatey
Then reopen Git Bash so the new jq.exe is on PATH, and re-run this installer.
MSG
  else
    cat >&2 <<'MSG'
  sudo apt install -y jq      # Debian/Ubuntu/WSL
  brew install jq             # macOS
MSG
  fi
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
#
# Under Git Bash / MSYS2 / Cygwin that shell is cmd.exe, not this one — Claude Code
# is the native Windows build and spawns the command through %ComSpec%. Two things
# follow, and either one alone is fatal:
#
#   1. `bash` is not on the Windows PATH. Git for Windows only puts its `cmd`
#      directory there, which holds git.exe and no shell. What `bash` DOES resolve
#      to on Windows 10/11 is C:\Windows\System32\bash.exe — the WSL launcher,
#      present whether or not a distribution is installed. So the POSIX spelling
#      does not fail loudly, it hands the statusline to WSL, which on a machine
#      without a distro answers with an error on stderr and nothing on stdout.
#      That is exactly what "installed under Git Bash, statusline never appears"
#      looks like. The fix is to name bash.exe by absolute Windows path.
#   2. cmd.exe cannot resolve MSYS paths: /c/Users/... is not a Windows path, and
#      the interpreter above would be handed a filename it cannot open. The script
#      path has to be written in Windows form too.
#
# Quoting there is cmd.exe's, not POSIX's — printf %q would emit backslash escapes
# that cmd passes through as literal characters. Windows paths cannot contain `"`,
# so a plain pair of double quotes around each half is both sufficient and safe,
# and it covers the "Program Files" space that this path almost always has.

# Windows path (C:/foo/bar) -> drive-letter POSIX path (/c/foo/bar).
#
# Deliberately not `cygpath -u`: that applies the MSYS mount table, under which
# /bin is remapped onto /usr/bin. The two bash.exe candidates below differ exactly
# there, so cygpath -u would collapse them and make the -f test inspect the wrong
# file. The drive-letter form bypasses the mount table and tests what it names.
win_to_posix() {
  case "$1" in
    [A-Za-z]:*)
      printf '/%s%s' \
        "$(printf '%s' "${1%%:*}" | tr '[:upper:]' '[:lower:]')" \
        "${1#*:}"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# Absolute Windows path of the bash that must run the renderer, or non-zero if
# this layout has none. <root>/bin/bash.exe is preferred: on Git for Windows that
# is the launcher, which sets MSYSTEM=MINGW64 and so puts /mingw64/bin — where git
# lives — on PATH. <root>/usr/bin/bash.exe is the bare interpreter, correct for a
# plain MSYS2 install, which has no top-level bin at all.
#
# Two probe passes, because no single POSIX spelling is right on every layout:
#
#   1. The drive-letter form, from win_to_posix. Correct on MSYS/MinGW, which mount
#      drives at /c — and the only form that can tell the two candidates apart
#      there, since the mount table aliases /bin onto /usr/bin.
#   2. cygpath -u, which is mount-aware. This is the pass that finds anything on
#      Cygwin, where drives live under /cygdrive/c and pass 1 therefore matches
#      nothing at all. Its /bin-vs-/usr/bin blindness costs nothing here: Cygwin
#      has no separate usr/bin on disk, so the first candidate is the right answer,
#      and on MSYS pass 1 has already returned before this runs.
windows_bash_path() {
  local root candidate
  command -v cygpath >/dev/null 2>&1 || return 1
  root="$(cygpath -m / 2>/dev/null)" || return 1
  [ -n "$root" ] || return 1
  root="${root%/}"
  for candidate in "$root/bin/bash.exe" "$root/usr/bin/bash.exe"; do
    if [ -f "$(win_to_posix "$candidate")" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  for candidate in "$root/bin/bash.exe" "$root/usr/bin/bash.exe"; do
    if [ -f "$(cygpath -u "$candidate" 2>/dev/null)" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

status_command=""
if [ "$IS_WINDOWS_BASH" = true ]; then
  if windows_bash_exe="$(windows_bash_path)"; then
    status_command="\"$windows_bash_exe\" \"$(cygpath -m "$CONFIG_DIR/statusline-command.sh")\""
  else
    # Falling through to the POSIX spelling would wire up a statusline that cannot
    # run, and report success doing it. Say so instead — the install is still fine,
    # it is only this one string that needs a hand.
    echo "Warning: could not locate bash.exe under this MSYS root (cygpath missing or"
    echo "         an unexpected layout). Falling back to the POSIX command spelling,"
    echo "         which native Windows Claude Code cannot run — if the statusline"
    echo "         stays blank, set statusLine.command by hand to:"
    echo "           \"C:/Program Files/Git/bin/bash.exe\" \"<config-dir>/statusline-command.sh\""
  fi
fi
if [ -z "$status_command" ]; then
  status_command="bash $(printf '%q' "$CONFIG_DIR/statusline-command.sh")"
fi

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
