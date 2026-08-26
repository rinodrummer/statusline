#!/bin/bash

# Output preview (2 lines):
#
#   Line 1: <agent> [Model | ███▒░░ 62% / 200K] [5h ███▓░ 71% ↻18:40] [7d ██▒░░ 45% ↻3d] (folder) my-project + 2 dirs
#   Line 2: my-project ((branch) main > +2 ~1) [wt:feature <- main] (clock) 14:30 (1h 12m)
#
# - Agent name only shown for subagents (e.g. "dotfiles-maintainer")
# - (folder), (branch), (clock) = Nerd Font icons
# - Progress bars use a sub-cell shade gradient: each cell carries 4 sub-levels (░ light, ▒ medium,
#   ▓ dark, █ full), so a bar resolves to width*4 steps rather than whole-cell-only fill
# - ⚠ appears before the bar when context exceeds 200k tokens (yellow >=200K, orange >=300K, red >=400K)
# - CONTEXT bar+percentage colour escalates too, dual-mode depending on the model's context window size:
#   1M-context models threshold on absolute used tokens (cream 256-color 230 >=200K, light orange 216 >=300K,
#   rosé 210 >=400K); 200K models threshold on used percentage instead (same colours at >=70%/80%/90%).
#   Plain/uncoloured below the lowest threshold in both modes.
# - [5h ...] shows the Claude.ai 5-hour rate-limit usage; omitted entirely when unavailable (e.g. API-key auth).
#   Its bar+percentage colour escalates with used_percentage: plain <50%, pale cream yellow (256-color 229)
#   50-84%, dark orange (256-color 202) 85-89%, red (256-color 196) >=90%. The "[5h " / "]" brackets and
#   the " ↻HH:MM" reset clock take a faint (dim) variant of the same ramp colour, so the group reads as
#   one colour with the bar+percentage dominant; below 50% this faint variant is just dim white, same as before.
# - [7d ...] shows the Claude.ai 7-day (weekly) rate-limit usage, mirroring the [5h] ramp/colour rules exactly
#   (same 50/85/90 thresholds, same palette, same muted-brackets/full-strength-bar split). Opt-in only: it
#   renders solely when `sections.seven_day` is true in `.statusline-settings` (see below) — false or missing
#   means the group is omitted entirely, no spacing left behind. Its reset marker is " ↻Nd" (days remaining,
#   ceil-rounded, floor of 1d) instead of a clock, since a weekly window resets days out; the marker is dropped
#   if `resets_at` is missing or non-numeric.
# - Settings live in one consolidated JSON file, `.statusline-settings`, in the config dir (same cascade as
#   the other flag files). Canonical shape (see statusline-settings.schema.json in the repo root):
#     {"style": "compact"|"verbose", "nerd_font": true, "badge": "<raw badge string>",
#      "sections": {"context": true, "five_hour": true, "seven_day": false, "advisor": true, "effort": true,
#                   "caveman": true, "ponytail": true, "git": true, "session_start_date": true, "agent": true}}
#   Stored values are canonical: statusline-settings.js folds case on the way in (`style=VERBOSE`) and
#   normalises booleans, so the comparisons below are exact on purpose. A hand-edited "VERBOSE" is NOT
#   honoured — it degrades to the default here exactly as it does in statusline-settings.js, which is what
#   keeps the two readers agreeing. Do not add tolerance to one side alone.
#   Missing/unreadable/malformed file degrades silently to those defaults (and no badge). If
#   `.statusline-settings` doesn't exist yet, `style` falls back to the legacy `.statusline-style` flag file
#   (content "verbose" = extended labels) so upgrades don't lose the current setting; once
#   `.statusline-settings` exists it wins outright and the legacy file is ignored.
# - Every `sections.*` key gates one renderable group: false omits it entirely, leaving no separator or double
#   space behind (each group carries its own leading space, so an empty one collapses cleanly). `context`
#   gates the bar/percentage/window run INSIDE the model bracket, which still renders as a bare [Model] —
#   the model name has no gate of its own. `session_start_date` gates the whole line-2 clock group (icon,
#   start time and duration), which is what `/statusline-options clock=false` sets.
# - `weekly` is the superseded storage key for `sections.seven_day`, still honoured on read in both shapes ever
#   written ("on"/"off" strings and booleans). The canonical key wins when both are present; the alias is
#   dropped from the file the next time statusline-settings.js writes it.
# - `sections.agent` gates the agent label like any other section: true (the default) shows it whenever the
#   session input carries `.agent.name`, false never does. "Subagents only" is not a rule this script applies —
#   it is what the data does, since Claude Code populates `.agent.name` for subagents alone. If that ever
#   changes and "always" becomes distinct from "subagents only", this key needs a third state; until then a
#   boolean says everything that is true.
# - Profile badge: a non-empty `badge` key in `.statusline-settings` wins outright. An explicit empty string
#   does NOT count as "set" (it falls through, so it can never mask a real badge file). Otherwise falls back
#   to the dedicated `statusline-badge.txt` file in the same config dir, for machines not yet migrated onto
#   the consolidated settings file.
# - Git status, in order: ↑ ahead, ☑ staged-new (check_square_o, light green), ⊞ untracked (plus_square_o,
#   green), ~ modified, - deleted, ✓ clean. Staged precedes untracked, mirroring porcelain's XY columns:
#   index-side state first, working-tree state after.
# - `nerd_font` (top-level, default true) declares whether the terminal has a Nerd Font. It is NOT a section:
#   it hides nothing, it only picks which glyphs the git group draws with — which is why it sits beside
#   `style` rather than under `sections`. Absent, empty or non-boolean all mean true, so existing files keep
#   their icons. false swaps exactly the Private Use Area glyphs (U+E000-U+F8FF, the Nerd-Font-only
#   codepoints that draw as a tofu box without the font) for ones any font has:
#     ahead U+F176 -> ↑ (U+2191), staged-new U+F046 -> ^, untracked U+F196 -> +,
#     modified U+F044 -> ~, deleted U+F147 -> -, and the group's leading branch icon U+E725 -> "git".
#   The + / ^ / ↑ run is ordered as the lifecycle it describes: + new, ^ staged (rising), ↑ gone up.
#   Ordinary Unicode is deliberately NOT degraded: ✓ clean is U+2713 (Dingbats) and ↑ is U+2191 (Arrows),
#   both render without a Nerd Font, so ✓ is identical in both modes and ahead only loses its PUA form.
#   Colours are identical in both modes — only the glyph changes. There is no auto-detection and must not be:
#   font support is invisible from a terminal, and no TERM_PROGRAM/WT_SESSION heuristic can tell a real glyph
#   from a tofu box, so the user declares it.
# - Config dir, in precedence order: `--config-dir <path>` (or `--config-dir=<path>`), $STATUSLINE_CONFIG_DIR,
#   $CLAUDE_CONFIG_DIR, then a probe of $HOME/.claude followed by $USERPROFILE/.claude, falling back to
#   $HOME/.claude. The first three are explicit and short-circuit the probe outright — an explicit dir is
#   honoured whether or not the file being looked for exists there, so a profile with no badge reads as
#   "no badge" rather than silently borrowing another dir's. Only the probe is per-file, and deliberately so:
#   see resolve_config_dir below for why the five callers must not be collapsed into one shared dir.

# Every `git` call below is read-only, but `git status` still takes .git/index.lock
# to refresh the index — and this script runs on every render, against whatever repo
# the user is sitting in. That collides with their own work: a `git pull` racing a
# render dies with "Unable to create '.git/index.lock': File exists". Rendering a
# prompt must never be able to fail someone's git command, so opt out of the
# optional locks entirely; the counters below read the same either way.
export GIT_OPTIONAL_LOCKS=0

# --- Argument parsing ---------------------------------------------------------
#
# Claude Code invokes this script with no arguments and the session JSON on
# stdin, so this loop is a no-op there and cannot disturb the read below. It runs
# before `input=$(cat)` purely for readability; it consumes no stdin either way.
# Unknown arguments are ignored rather than fatal: this renders a prompt, and
# aborting on an argument a future Claude Code might pass would cost the user
# their whole statusline over something cosmetic.
_cli_config_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir=*) _cli_config_dir="${1#--config-dir=}" ;;
    --config-dir)   _cli_config_dir="${2:-}"; shift ;;
    *) ;;
  esac
  shift
done

# --- Config dir resolution ----------------------------------------------------
#
# Resolves the config dir for ONE probe file, given as "$@" (several filenames
# mean "any of these"; the first dir carrying any of them wins).
#
# Explicit sources — the --config-dir argument, then $STATUSLINE_CONFIG_DIR, then
# $CLAUDE_CONFIG_DIR — win in that order and skip the probe entirely, so an
# explicit dir is returned even when it holds none of the probe files. That is
# what makes a profile's *absent* file read as absent instead of falling through
# to another profile's copy of it.
#
# The probe fallback is per-file, and this function is therefore CALLED once per
# call site rather than once overall. The $USERPROFILE branch exists for machines
# carrying both a Linux $HOME/.claude and a Windows $USERPROFILE/.claude, and on
# those the probe files have independent producers (statusline-settings.js,
# caveman-activate.js, install.sh, create-statusline-badge.sh) that write at
# different times to whichever side they run on. Nothing keeps them co-located.
# Resolving one dir for all five would let the location of one file decide where
# the other four are read from — settings found under $HOME would stop a caveman
# flag living only under $USERPROFILE from ever being seen. Each file finds its
# own dir; only the code is shared.
resolve_config_dir() {
  local _probe
  if [ -n "$_cli_config_dir" ]; then
    printf '%s' "$_cli_config_dir"; return
  fi
  if [ -n "${STATUSLINE_CONFIG_DIR:-}" ]; then
    printf '%s' "$STATUSLINE_CONFIG_DIR"; return
  fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s' "$CLAUDE_CONFIG_DIR"; return
  fi
  for _probe in "$@"; do
    if [ -f "$HOME/.claude/$_probe" ]; then
      printf '%s' "$HOME/.claude"; return
    fi
  done
  if [ -n "$USERPROFILE" ]; then
    for _probe in "$@"; do
      if [ -f "$USERPROFILE/.claude/$_probe" ]; then
        printf '%s' "$USERPROFILE/.claude"; return
      fi
    done
  fi
  printf '%s' "$HOME/.claude"
}

input=$(cat)

# --- Consolidated settings: .statusline-settings ------------------------------
#
# Parsed once, up front, because the section gates below decide whether whole
# groups are computed at all. Malformed/unreadable JSON degrades silently to the
# defaults (compact, no badge, every section on except seven_day):
# a failed jq leaves every variable empty, and empty means "fall back", so the
# defaults below are the single source of truth on the bash side.
#
# Falls back to the legacy .statusline-style file (content-based: "verbose" =
# extended labels) only when .statusline-settings doesn't exist yet, so upgrades
# don't lose the current setting; once .statusline-settings exists it wins
# outright and the legacy file is ignored (the legacy path has no equivalent for
# any other key — the badge always falls to statusline-badge.txt, see below).
#
# The one-value-per-line shape below (not @tsv) is deliberate: @tsv escapes
# embedded backslashes/tabs to keep the row parseable, which would double every
# backslash in an ANSI badge (\x1b -> \\x1b) and print as literal text once
# printf gets it. Plain jq -r raw output does no such re-escaping, so each value
# is emitted on its own line (jq's normal behaviour for a comma-separated filter)
# and read back with one `read` per line — no separator character needed, so
# nothing to clash with a byte the badge might legitimately contain. The badge is
# read LAST for the same reason a badge is hard: it is the only value that could
# itself contain a newline, and trailing garbage lines are harmless.
# Two probe files: either the consolidated settings or the legacy style flag
# anchors the dir, since a machine on the legacy flag alone has no other marker.
_settings_dir=$(resolve_config_dir .statusline-settings .statusline-style)
_settings_file="$_settings_dir/.statusline-settings"
_style_value=""
_nerd_font_value=""
_badge_value=""
_sec_agent=""
_sec_context=""
_sec_five_hour=""
_sec_seven_day=""
_sec_advisor=""
_sec_effort=""
_sec_caveman=""
_sec_ponytail=""
_sec_git=""
_sec_session_start_date=""
if [ -f "$_settings_file" ]; then
  # A section key emits its boolean, or "" when absent/not-a-boolean so the bash
  # default applies. seven_day additionally honours the superseded "weekly" key
  # (written as "on"/"off" strings by older versions, as a boolean by the schema)
  # — but only when the canonical sections.seven_day says nothing, so an explicit
  # canonical value is never overridden by the alias it replaced.
  _settings_parsed=$(jq -r '
    def section(name):
      if (.sections[name] | type) == "boolean" then (.sections[name] | tostring) else "" end;
    (.style // ""),
    (if (.nerd_font | type) == "boolean" then (.nerd_font | tostring) else "" end),
    section("agent"),
    section("context"),
    section("five_hour"),
    (if (.sections.seven_day | type) == "boolean" then (.sections.seven_day | tostring)
     elif (.weekly | type) == "boolean" then (.weekly | tostring)
     elif .weekly == "on" then "true"
     elif .weekly == "off" then "false"
     else "" end),
    section("advisor"),
    section("effort"),
    section("caveman"),
    section("ponytail"),
    section("git"),
    section("session_start_date"),
    (.badge // "")
  ' "$_settings_file" 2>/dev/null)
  # jq.exe on Windows writes its stdout in text mode, so every one of the lines
  # above arrives terminated by CRLF rather than LF. `$(...)` hides that for the
  # single-value reads elsewhere in this script — MSYS bash strips one trailing CR
  # off a command substitution — but `read` does not, and this is the only place
  # that reads. Left in, the CR rides along on every value: `_style_value` becomes
  # "verbose\r" and never equals "verbose", and worse, an *absent* section key
  # arrives as "\r" instead of "", which is non-empty, so section_enabled skips its
  # default and evaluates it as false. The visible result on Git Bash is a
  # statusline stripped down to `[Model] (folder) dir` — every section off, style
  # stuck on compact — the moment a .statusline-settings file exists at all.
  #
  # Stripped here rather than per-variable so the positional list stays a list, and
  # by parameter expansion rather than `tr -d '\r'` to keep a process off a path
  # that runs on every render. No legitimate value can contain a CR: the badge is a
  # single line by construction, and everything else is an enum or a boolean.
  _settings_parsed="${_settings_parsed//$'\r'/}"
  {
    IFS= read -r _style_value
    IFS= read -r _nerd_font_value
    IFS= read -r _sec_agent
    IFS= read -r _sec_context
    IFS= read -r _sec_five_hour
    IFS= read -r _sec_seven_day
    IFS= read -r _sec_advisor
    IFS= read -r _sec_effort
    IFS= read -r _sec_caveman
    IFS= read -r _sec_ponytail
    IFS= read -r _sec_git
    IFS= read -r _sec_session_start_date
    IFS= read -r _badge_value
  } <<< "$_settings_parsed"
else
  _style_content=$(cat "$_settings_dir/.statusline-style" 2>/dev/null)
  _style_content="${_style_content#"${_style_content%%[![:space:]]*}"}"
  _style_content="${_style_content%"${_style_content##*[![:space:]]}"}"
  [ "$_style_content" = "verbose" ] && _style_value="verbose"
fi
_style_value="${_style_value:-compact}"
[ "$_style_value" = "verbose" ] && statusline_verbose=1 || statusline_verbose=

# Section gate: `section_enabled <value> <default>` — an empty value (key absent,
# not a boolean, or the whole file unreadable) falls back to the schema default.
section_enabled() {
  local _value="$1" _default="$2"
  [ -z "$_value" ] && _value="$_default"
  [ "$_value" = "true" ]
}

# Extract fields from JSON input
model_display=$(echo "$input" | jq -r '.model.display_name // .model // "unknown"')
cwd=$(echo "$input" | jq -r '.cwd // "."')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
exceeds_200k=$(echo "$input" | jq -r '.exceeds_200k_tokens // false')
transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')

# Format context size (e.g. 200000 => 200K, 1000000 => 1M, 1000000000 => 1B)
if [ "$context_size" -ge 1000000000 ] 2>/dev/null; then
  context_fmt="$((context_size / 1000000000))B"
elif [ "$context_size" -ge 1000000 ] 2>/dev/null; then
  context_fmt="$((context_size / 1000000))M"
elif [ "$context_size" -ge 1000 ] 2>/dev/null; then
  context_fmt="$((context_size / 1000))K"
else
  context_fmt="$context_size"
fi

# Platform detection
_os=$(uname -s)

# Session start time and duration — the whole line-2 clock group, gated by
# sections.session_start_date (`/statusline-options clock=false`). Skipped
# outright when off: an empty time_part collapses its own separator downstream.
if ! section_enabled "$_sec_session_start_date" true; then
  time_part=""
elif [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  if [ "$_os" = "Darwin" ]; then
    start_epoch=$(stat -f '%B' "$transcript_path" 2>/dev/null)
  else
    start_epoch=$(stat -c '%W' "$transcript_path" 2>/dev/null)
  fi
  if [ -n "$start_epoch" ] && [ "$start_epoch" -gt 0 ] 2>/dev/null; then
    if [ "$_os" = "Darwin" ]; then
      start_date=$(date -r "$start_epoch" '+%d/%m/%Y')
      today=$(date '+%d/%m/%Y')
      if [ "$start_date" = "$today" ]; then
        start_time=$(date -r "$start_epoch" '+%H:%M')
      else
        start_time="${start_date} $(date -r "$start_epoch" '+%H:%M')"
      fi
    else
      start_date=$(date -d "@$start_epoch" '+%d/%m/%Y')
      today=$(date '+%d/%m/%Y')
      if [ "$start_date" = "$today" ]; then
        start_time=$(date -d "@$start_epoch" '+%H:%M')
      else
        start_time="${start_date} $(date -d "@$start_epoch" '+%H:%M')"
      fi
    fi
    now_epoch=$(date '+%s')
    elapsed=$((now_epoch - start_epoch))
    hours=$((elapsed / 3600))
    minutes=$(( (elapsed % 3600) / 60 ))
    seconds=$((elapsed % 60))
    if [ "$hours" -gt 0 ]; then
      duration="${hours}h${minutes}m${seconds}s"
    elif [ "$minutes" -gt 0 ]; then
      duration="${minutes}m${seconds}s"
    else
      duration="${seconds}s"
    fi
    time_part=" \x1b[2;37m${start_time} (${duration})\x1b[0m"
  else
    time_part=""
  fi
else
  time_part=""
fi

# Warning icon if exceeding 200k tokens; color escalates by used token count:
#   >= 400K used: red, >= 300K used: orange (256-color), >= 200K used: yellow
used_tokens=$(echo "$used_pct $context_size" | awk '{printf "%d", $1 * $2 / 100}' 2>/dev/null)
if [ "$exceeds_200k" = "true" ]; then
  if [ "$used_tokens" -ge 400000 ] 2>/dev/null; then
    warn="\x1b[1;31m\xef\x81\xb1 \x1b[0m"
  elif [ "$used_tokens" -ge 300000 ] 2>/dev/null; then
    warn="\x1b[1;38;5;208m\xef\x81\xb1 \x1b[0m"
  else
    warn="\x1b[1;33m\xef\x81\xb1 \x1b[0m"
  fi
else
  warn=""
fi

# Build a block-glyph progress bar with a sub-cell shade gradient: render_bar <pct> <width>
# Each cell has 4 sub-levels, so the bar resolves to width*4 steps rather than whole-cell-only fill.
render_bar() {
  local _pct=$1 _width=$2 _total _full _rem _bar i
  _total=$((_pct * _width * 4 / 100))
  _full=$((_total / 4))
  _rem=$((_total % 4))
  if [ "$_full" -gt "$_width" ]; then
    _full=$_width
  fi
  _bar=""
  for ((i=0; i<_full; i++)); do _bar+="\xe2\x96\x88"; done
  if [ "$_rem" -gt 0 ] && [ "$_full" -lt "$_width" ]; then
    case "$_rem" in
      1) _bar+="\xe2\x96\x91" ;;
      2) _bar+="\xe2\x96\x92" ;;
      3) _bar+="\xe2\x96\x93" ;;
    esac
    _full=$((_full + 1))
  fi
  for ((i=_full; i<_width; i++)); do _bar+="\xe2\x96\x91"; done
  echo "$_bar"
}

# Context progress bar
pct=${used_pct%%.*}
context_bar_width=6
bar=$(render_bar "$pct" "$context_bar_width")

# Colour escalation for the bar+percentage run only. Dual-mode, driven by context_size:
#   - 1M-context models (context_size > 200K): threshold on absolute used_tokens.
#   - 200K models: threshold on pct, same as before.
# Bucket first (case can't do numeric ranges), then map the bucket to a colour.
if [ "$context_size" -gt 200000 ] 2>/dev/null; then
  if [ "$used_tokens" -ge 400000 ] 2>/dev/null; then
    _context_bucket=3
  elif [ "$used_tokens" -ge 300000 ] 2>/dev/null; then
    _context_bucket=2
  elif [ "$used_tokens" -ge 200000 ] 2>/dev/null; then
    _context_bucket=1
  else
    _context_bucket=0
  fi
else
  if [ "$pct" -ge 90 ] 2>/dev/null; then
    _context_bucket=3
  elif [ "$pct" -ge 80 ] 2>/dev/null; then
    _context_bucket=2
  elif [ "$pct" -ge 70 ] 2>/dev/null; then
    _context_bucket=1
  else
    _context_bucket=0
  fi
fi
case "$_context_bucket" in
  3) context_colour="\x1b[38;5;210m" ;;
  2) context_colour="\x1b[38;5;216m" ;;
  1) context_colour="\x1b[38;5;230m" ;;
  *) context_colour="" ;;
esac
if [ -n "$context_colour" ]; then
  context_colour_reset="\x1b[0m"
else
  context_colour_reset=""
fi

# 5-hour session-limit bar (Claude.ai subscription only; absent for API-key auth).
# Gated by sections.five_hour; the group carries its own leading space, so an
# empty five_hour_part leaves no gap behind.
five_hour_bar_width=5
if section_enabled "$_sec_five_hour" true; then
  five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
  five_hour_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
else
  five_hour_pct=""
fi
if [ -n "$five_hour_pct" ]; then
  five_hour_int=${five_hour_pct%%.*}
  five_hour_bar=$(render_bar "$five_hour_int" "$five_hour_bar_width")

  # Colour escalation for the bar+percentage run only, driven by used_percentage.
  # Bucket first (case can't do numeric ranges), then map the bucket to a colour pair.
  if [ "$five_hour_int" -ge 90 ] 2>/dev/null; then
    _five_hour_bucket=3
  elif [ "$five_hour_int" -ge 85 ] 2>/dev/null; then
    _five_hour_bucket=2
  elif [ "$five_hour_int" -ge 50 ] 2>/dev/null; then
    _five_hour_bucket=1
  else
    _five_hour_bucket=0
  fi
  case "$_five_hour_bucket" in
    3) five_hour_colour="\x1b[38;5;196m" ; five_hour_muted="\x1b[2;38;5;196m" ;;
    2) five_hour_colour="\x1b[38;5;202m" ; five_hour_muted="\x1b[2;38;5;202m" ;;
    1) five_hour_colour="\x1b[38;5;229m" ; five_hour_muted="\x1b[2;38;5;229m" ;;
    *) five_hour_colour="" ; five_hour_muted="\x1b[2;37m" ;;
  esac
  if [ -n "$five_hour_colour" ]; then
    five_hour_colour_reset="\x1b[0m"
  else
    five_hour_colour_reset=""
  fi

  five_hour_reset_part=""
  if [ -n "$five_hour_resets" ]; then
    # resets_at has two possible shapes: a Unix epoch (seconds or, rarely,
    # milliseconds) as a bare number, or an ISO-8601 string. Detect numeric
    # via pattern match rather than a parse-and-catch.
    case "$five_hour_resets" in
      ''|*[!0-9]*) _five_hour_is_epoch=0 ;;
      *)           _five_hour_is_epoch=1 ;;
    esac
    if [ "$_five_hour_is_epoch" = "1" ]; then
      _five_hour_epoch="$five_hour_resets"
      # 12+ digits => milliseconds, not seconds
      [ ${#_five_hour_epoch} -ge 12 ] && _five_hour_epoch=$((_five_hour_epoch / 1000))
      if [ "$_os" = "Darwin" ]; then
        five_hour_reset_time=$(date -r "$_five_hour_epoch" '+%H:%M' 2>/dev/null)
      else
        five_hour_reset_time=$(date -d "@$_five_hour_epoch" '+%H:%M' 2>/dev/null)
      fi
    else
      if [ "$_os" = "Darwin" ]; then
        _five_hour_iso="${five_hour_resets%%.*}"
        _five_hour_iso="${_five_hour_iso%Z}"
        five_hour_reset_time=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$_five_hour_iso" '+%H:%M' 2>/dev/null)
      else
        five_hour_reset_time=$(date -d "$five_hour_resets" '+%H:%M' 2>/dev/null)
      fi
    fi
    if [ -n "$five_hour_reset_time" ]; then
      if [ "$_five_hour_bucket" = "0" ]; then
        five_hour_reset_part=" \xe2\x86\xbb${five_hour_reset_time}"
      else
        five_hour_reset_part=" ${five_hour_muted}\xe2\x86\xbb${five_hour_reset_time}\x1b[0m"
      fi
    fi
  fi
  five_hour_part=" ${five_hour_muted}[5h \x1b[0m${five_hour_colour}${five_hour_bar} ${five_hour_int}%%${five_hour_colour_reset}${five_hour_reset_part}${five_hour_muted}]\x1b[0m"
else
  five_hour_part=""
fi

# Current directory name (not full path)
dir_name=$(basename "$cwd")

# Added dirs (extra directories in workspace)
#
# Backslashes are folded to slashes before the split because Claude Code running
# natively on Windows sends Windows paths ("D:\\git\\dotfiles"). Splitting those
# on "/" alone yields one element, so `last` returns the whole path and the line
# prints "D:\git\dotfiles" where every other platform prints "dotfiles". basename
# needs no such help — MSYS's accepts either separator — but jq is not MSYS.
added_dirs=$(echo "$input" | jq -r '.workspace.added_dirs // [] | map(gsub("\\\\"; "/") | split("/") | last) | join(", ")' 2>/dev/null)
if [ -n "$added_dirs" ]; then
  added_dirs_part=" + \x1b[2;34m${added_dirs}\x1b[0m"
else
  added_dirs_part=""
fi

# Project name (from package.json if available, otherwise git root basename)
project_name=""
project_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$project_root" ] && [ -f "$project_root/package.json" ]; then
  project_name=$(jq -r '.name // empty' "$project_root/package.json" 2>/dev/null)
fi
if [ -z "$project_name" ]; then
  project_name=$(basename "${project_root:-$cwd}")
fi

# Repo name (git root directory name)
if [ -n "$project_root" ]; then
  repo_name=$(basename "$project_root")
else
  repo_name=""
fi

# Git branch — gated by sections.git, which covers the whole line-2 git group
# (repo, branch, status icons and the worktree marker that hangs off it).
if section_enabled "$_sec_git" true; then
  git_branch=$(git -C "$cwd" branch --show-current 2>/dev/null || echo "")
else
  git_branch=""
fi

# Git status
if [ -n "$git_branch" ]; then
  # Commits ahead of remote
  ahead=$(git -C "$cwd" rev-list --count @{upstream}..HEAD 2>/dev/null || echo "0")
  # Working tree + staged file counts
  # BRE: bare '?' is literal here, '\?' would be the optional-atom operator
  added=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -c '^A')
  untracked=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -c '^??')
  modified=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -c '^.\?M')
  deleted=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -c '^.\?D')

  # Glyph set, chosen by nerd_font. The fallbacks replace exactly the Private Use
  # Area glyphs (U+E000-U+F8FF) — the Nerd-Font-only codepoints that draw as a
  # tofu box without the font. Ordinary Unicode is NOT degraded: ↑ (U+2191) and
  # ✓ (U+2713) live in Arrows and Dingbats, render in any normal font, and are
  # already the vocabulary this file's header uses for those two entries.
  # The three-symbol run is ordered as the lifecycle it describes, left to right:
  # + is new, ^ is staged (rising), ↑ is already gone up.
  # Colours are identical in both sets — only the glyph changes, and each entry
  # keeps its single trailing space so the `% }` trim below works either way.
  #
  # Compared against "false" exactly: absent, empty or non-boolean all mean true,
  # which is what keeps every existing settings file rendering icons untouched.
  # Stored values are canonical (statusline-settings.js normalises on write), so
  # an exact match is deliberate here, as everywhere else in this file.
  if [ "$_nerd_font_value" = "false" ]; then
    _icon_ahead="\xe2\x86\x91"      # U+2191 ↑
    _icon_added="^"
    _icon_untracked="+"
    _icon_modified="~"
    _icon_deleted="-"
    _icon_git="git"
  else
    _icon_ahead="\xef\x85\xb6"
    _icon_added="\xef\x81\x86"
    _icon_untracked="\xef\x86\x96"
    _icon_modified="\xef\x81\x84"
    _icon_deleted="\xef\x85\x87"
    _icon_git="\xee\x9c\xa5"
  fi

  git_status=""
  [ "$ahead" -gt 0 ] 2>/dev/null && git_status+="\x1b[33m${_icon_ahead} ${ahead}\x1b[0m "
  [ "$added" -gt 0 ] 2>/dev/null && git_status+="\x1b[38;5;120m${_icon_added} ${added}\x1b[0m "
  [ "$untracked" -gt 0 ] 2>/dev/null && git_status+="\x1b[32m${_icon_untracked} ${untracked}\x1b[0m "
  [ "$modified" -gt 0 ] 2>/dev/null && git_status+="\x1b[34m${_icon_modified} ${modified}\x1b[0m "
  [ "$deleted" -gt 0 ] 2>/dev/null && git_status+="\x1b[31m${_icon_deleted} ${deleted}\x1b[0m "
  git_status="${git_status% }"
  # ✓ is U+2713 (Dingbats), not a Nerd Font glyph, so it is the same in both sets.
  [ -z "$git_status" ] && git_status="\x1b[32m\xe2\x9c\x93\x1b[0m"
  # Worktree info
  wt_name=$(echo "$input" | jq -r '.worktree.name // ""')
  wt_branch=$(echo "$input" | jq -r '.worktree.branch // ""')
  wt_original_branch=$(echo "$input" | jq -r '.worktree.original_branch // ""')
  if [ -n "$wt_name" ]; then
    worktree_part=" \x1b[2;37m[\x1b[0m\x1b[1;36m${wt_name}\x1b[0m\x1b[2;37m:\x1b[0m\x1b[36m${wt_branch}\x1b[0m \x1b[2;37m<- ${wt_original_branch}]\x1b[0m"
  else
    worktree_part=""
  fi

  # Show repo name if it differs from both dir_name and project_name
  git_icon="$_icon_git"
  if [ -n "$repo_name" ] && [ "$repo_name" != "$dir_name" ] && [ "$repo_name" != "$project_name" ]; then
    git_part=" (${git_icon} \x1b[33m${repo_name}\x1b[0m > \x1b[36m${git_branch}\x1b[0m > ${git_status})${worktree_part}"
  else
    git_part=" (${git_icon} \x1b[36m${git_branch}\x1b[0m > ${git_status})${worktree_part}"
  fi
else
  git_part=""
fi

# Agent name, gated by sections.agent: on (the default) shows it whenever the
# input carries .agent.name, which today means subagents only — that condition is
# the data's, not this script's, so there is nothing here to enforce it.
if section_enabled "$_sec_agent" true; then
  agent_name=$(echo "$input" | jq -r '.agent.name // ""')
else
  agent_name=""
fi
if [ -n "$agent_name" ]; then
  agent_part="\x1b[1;32m${agent_name}\x1b[0m "
else
  agent_part=""
fi

# 7-day weekly rate-limit bar — same shape/ramp as the 5h block above, rendered right after it on line 1.
# Opt-in via sections.seven_day (the superseded "weekly" alias still feeds it, resolved at parse time up
# top); renders nothing at all (no spacing left behind) when off.
seven_day_part=""
if section_enabled "$_sec_seven_day" false; then
  seven_day_bar_width=5
  seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
  seven_day_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
  if [ -n "$seven_day_pct" ]; then
    seven_day_int=${seven_day_pct%%.*}
    seven_day_bar=$(render_bar "$seven_day_int" "$seven_day_bar_width")

    # Colour escalation for the bar+percentage run only, driven by used_percentage. Bucket first
    # (case can't do numeric ranges), then map the bucket to a colour pair. Mirrors the 5h thresholds exactly.
    if [ "$seven_day_int" -ge 90 ] 2>/dev/null; then
      _seven_day_bucket=3
    elif [ "$seven_day_int" -ge 85 ] 2>/dev/null; then
      _seven_day_bucket=2
    elif [ "$seven_day_int" -ge 50 ] 2>/dev/null; then
      _seven_day_bucket=1
    else
      _seven_day_bucket=0
    fi
    case "$_seven_day_bucket" in
      3) seven_day_colour="\x1b[38;5;196m" ; seven_day_muted="\x1b[2;38;5;196m" ;;
      2) seven_day_colour="\x1b[38;5;202m" ; seven_day_muted="\x1b[2;38;5;202m" ;;
      1) seven_day_colour="\x1b[38;5;229m" ; seven_day_muted="\x1b[2;38;5;229m" ;;
      *) seven_day_colour="" ; seven_day_muted="\x1b[2;37m" ;;
    esac
    if [ -n "$seven_day_colour" ]; then
      seven_day_colour_reset="\x1b[0m"
    else
      seven_day_colour_reset=""
    fi

    # Reset marker is days remaining (ceil-rounded, floor of 1d), not a clock — a weekly window resets days
    # out. Dropped entirely if resets_at is missing, non-numeric, or already in the past.
    seven_day_reset_part=""
    if [ -n "$seven_day_resets" ]; then
      case "$seven_day_resets" in
        ''|*[!0-9]*) _seven_day_is_epoch=0 ;;
        *)           _seven_day_is_epoch=1 ;;
      esac
      if [ "$_seven_day_is_epoch" = "1" ]; then
        _seven_day_now=$(date '+%s')
        _seven_day_delta=$((seven_day_resets - _seven_day_now))
        if [ "$_seven_day_delta" -gt 0 ] 2>/dev/null; then
          _seven_day_days=$(( (_seven_day_delta + 86399) / 86400 ))
          [ "$_seven_day_days" -lt 1 ] 2>/dev/null && _seven_day_days=1
          if [ "$_seven_day_bucket" = "0" ]; then
            seven_day_reset_part=" \xe2\x86\xbb${_seven_day_days}d"
          else
            seven_day_reset_part=" ${seven_day_muted}\xe2\x86\xbb${_seven_day_days}d\x1b[0m"
          fi
        fi
      fi
    fi
    seven_day_part=" ${seven_day_muted}[7d \x1b[0m${seven_day_colour}${seven_day_bar} ${seven_day_int}%%${seven_day_colour_reset}${seven_day_reset_part}${seven_day_muted}]\x1b[0m"
  fi
fi

# Effort / thinking indicator, gated by sections.effort
if section_enabled "$_sec_effort" true; then
  thinking_enabled=$(echo "$input" | jq -r '.thinking.enabled // false')
  effort_level=$(echo "$input" | jq -r '.effort.level // ""')
else
  thinking_enabled="false"
  effort_level=""
fi
if [ "$thinking_enabled" = "true" ] || [ -n "$effort_level" ]; then
  case "$effort_level" in
    auto)        effort_badge="🧠~"  ; effort_label="auto" ;;
    low)         effort_badge="🧠▁"  ; effort_label="low" ;;
    medium)      effort_badge="🧠▃"  ; effort_label="medium" ;;
    high)        effort_badge="🧠▆"  ; effort_label="high" ;;
    highest|max) effort_badge="🧠█"  ; effort_label="max" ;;
    "")          effort_badge="🧠?"  ; effort_label="" ;;
    *)           effort_badge="🧠?"  ; effort_label="" ;;
  esac
  if [ -n "$statusline_verbose" ] && [ -n "$effort_label" ]; then
    effort_part=" 🧠 effort:${effort_label}"
  else
    effort_part=" ${effort_badge}"
  fi
else
  effort_part=""
fi

# Advisor indicator (read from Claude Code settings)
_advisor_dir=$(resolve_config_dir settings.json)
# Gated by sections.advisor: skip the settings.json read entirely when off.
if section_enabled "$_sec_advisor" true; then
  advisor_model=$(jq -r '.advisorModel // ""' "$_advisor_dir/settings.json" 2>/dev/null | tr -d '[:space:]')
else
  advisor_model=""
fi
if [ -n "$advisor_model" ]; then
  advisor_part=" \x1b[2;36m[advisor:${advisor_model}]\x1b[0m"
else
  advisor_part=""
fi


# Caveman mode indicator — reads flag written by caveman-activate.js
caveman_part=""
_caveman_dir=$(resolve_config_dir .caveman-active)
# Gated by sections.caveman: skip the flag-file read entirely when off.
if section_enabled "$_sec_caveman" true && [ -f "$_caveman_dir/.caveman-active" ]; then
  caveman_mode=$(tr -d '[:space:]' < "$_caveman_dir/.caveman-active" 2>/dev/null)
  case "$caveman_mode" in
    lite)          caveman_badge="🪨▁" ;;
    full)          caveman_badge="🪨▄" ;;
    ultra)         caveman_badge="🪨█" ;;
    wenyan-lite)   caveman_badge="🪨文▁" ;;
    wenyan)        caveman_badge="🪨文▄" ;;
    wenyan-ultra)  caveman_badge="🪨文█" ;;
    off|"")        caveman_badge="" ;;
    *)             caveman_badge="🪨?" ;;
  esac
  if [ -n "$caveman_badge" ]; then
    if [ -n "$statusline_verbose" ]; then
      caveman_part=" 🪨 caveman:${caveman_mode}"
    else
      caveman_part=" ${caveman_badge}"
    fi
  fi
fi

# Ponytail mode indicator — reads flag written by ponytail-activate hook
ponytail_part=""
_ponytail_dir=$(resolve_config_dir .ponytail-active)
# Gated by sections.ponytail: skip the flag-file read entirely when off.
if section_enabled "$_sec_ponytail" true && [ -f "$_ponytail_dir/.ponytail-active" ]; then
  ponytail_mode=$(tr -d '[:space:]' < "$_ponytail_dir/.ponytail-active" 2>/dev/null)
  case "$ponytail_mode" in
    lite)   ponytail_badge="🤓▁" ;;
    full)   ponytail_badge="🤓▄" ;;
    ultra)  ponytail_badge="🤓█" ;;
    off|"") ponytail_badge="" ;;
    *)      ponytail_badge="🤓?" ;;
  esac
  if [ -n "$ponytail_badge" ]; then
    if [ -n "$statusline_verbose" ]; then
      ponytail_part=" 🤓 ponytail:${ponytail_mode}"
    else
      ponytail_part=" ${ponytail_badge}"
    fi
  fi
fi

# Profile badge — the "badge" key parsed from .statusline-settings above wins outright when non-empty.
# An explicitly empty "badge" in settings does NOT count as set (falls through here on purpose, so it
# can never mask a real badge file). Otherwise falls back to the dedicated statusline-badge.txt file
# (raw badge string written by create-statusline-badge.sh), for machines not yet migrated onto the
# consolidated settings file. Same config-dir resolution as caveman/ponytail above.
badge_part=""
if [ -n "$_badge_value" ]; then
  badge_part="$_badge_value"
else
  _badge_dir=$(resolve_config_dir statusline-badge.txt)
  [ -f "$_badge_dir/statusline-badge.txt" ] && badge_part=$(cat "$_badge_dir/statusline-badge.txt" 2>/dev/null)
fi

# Line 1: <Badge> <Agent name> [Model | Progress bar] [5h bar] <advisor> <effort> <caveman> <ponytail> 📂 <Dir name>
#
# sections.context gates the run INSIDE the model bracket (warning icon, bar,
# percentage and window size); the bracket and the model name always render, so
# context=false leaves a bare [Model]. The conditional run carries printf
# conversions, so its arguments have to disappear with it — an extra argument
# would make printf reuse the whole format string and emit the line twice.
if section_enabled "$_sec_context" true; then
  context_run=" | ${warn}${context_colour}${bar} %d%%${context_colour_reset} \x1b[2;37m/ %s\x1b[0m"
  line1_args=("$model_display" "$pct" "$context_fmt" "$dir_name")
else
  context_run=""
  line1_args=("$model_display" "$dir_name")
fi
printf "${badge_part}${agent_part}[\x1b[1;33m%s\x1b[0m${context_run}]${five_hour_part}${seven_day_part}${advisor_part}${effort_part}${caveman_part}${ponytail_part} \xf0\x9f\x93\x82 \x1b[1;34m%s\x1b[0m${added_dirs_part}\n" \
  "${line1_args[@]}"
# Line 2: <Project name> <Git section> <Clock icon> <start time (duration)>
clock_icon="\xef\x80\x97"
printf "\x1b[1;35m%s\x1b[0m${git_part}${time_part:+ ${clock_icon}${time_part}}" "$project_name"
