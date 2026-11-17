#!/usr/bin/env bats
#
# Tests for .claude/statusline-command.sh — the only test that actually executes
# the statusline. The script is driven the way Claude Code drives it: the session
# JSON on stdin, the rendered two lines on stdout.
#
# Isolation: every test gets its own mktemp -d, with both CLAUDE_CONFIG_DIR and
# HOME pointed inside it. CLAUDE_CONFIG_DIR is where the config-dir cascade lands
# (advisor, caveman, ponytail, badge, settings all read from it); HOME is the
# fallback the cascade uses when CLAUDE_CONFIG_DIR is empty, and pointing it into
# the temp dir keeps the real ~/.claude from leaking into the output. USERPROFILE
# is unset so the Windows branch of the config-dir cascade can never fire.
#
# Assertions are on byte patterns observed from real runs (cat -A), not on what
# the source appears to emit: the escape-heavy output makes eyeballed expectations
# unreliable. Line 1 carries model/context/5h/7d/badge, line 2 project/git/time.
#
# Keep @test names ASCII-only. bats encodes each name into a shell function name,
# and under MSYS/Git Bash the multibyte round-trip does not survive: the test is
# reported as `bats: unknown test name` and never runs at all — silently dropping
# it from the count rather than failing. Spell glyphs under test as codepoints in
# the title (U+2191, U+2713); the assertions below use the real bytes.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../statusline-command.sh"
  TMP="$(mktemp -d)"
  export CLAUDE_CONFIG_DIR="$TMP/config"
  export HOME="$TMP/home"
  unset USERPROFILE
  WORKDIR="$TMP/work"
  mkdir -p "$CLAUDE_CONFIG_DIR" "$HOME" "$WORKDIR"
}

teardown() {
  rm -rf "$TMP"
}

# Minimal valid input. $1 = extra JSON keys (leading comma included by caller).
statusline_input() {
  printf '{"model":{"display_name":"M"},"cwd":"%s","context_window":{"used_percentage":42,"context_window_size":200000}%s}' \
    "$WORKDIR" "${1:-}"
}

# Input with a context window of a given size/percentage, for the bar colour tests.
context_input() {
  printf '{"model":{"display_name":"M"},"cwd":"%s","context_window":{"used_percentage":%s,"context_window_size":%s}}' \
    "$WORKDIR" "$1" "$2"
}

write_settings() {
  printf '%s' "$1" > "$CLAUDE_CONFIG_DIR/.statusline-settings"
}

# A throwaway git repo driven into real states — porcelain strings are never
# hand-crafted, since the point is to test the parsing of git's actual output.
init_repo() {
  git -C "$WORKDIR" init -q -b main
  git -C "$WORKDIR" -c user.email=test@example.com -c user.name=Test \
    commit -q --allow-empty -m "init"
}

epoch_in() {
  echo $(($(date '+%s') + $1))
}

# --- Consolidated settings: .statusline-settings ------------------------------

@test "sections.seven_day true: 7d group renders when seven_day is in the input" {
  write_settings '{"sections":{"seven_day":true}}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[7d "* ]]
  [[ "$output" == *"45%"* ]]
}

@test "sections.seven_day false: no 7d group even with seven_day in the input" {
  write_settings '{"sections":{"seven_day":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" != *"[7d"* ]]
}

# --- The superseded "weekly" alias --------------------------------------------
#
# Settings files in the wild hold weekly as "on"/"off" strings; the schema
# declares a boolean. The renderer has to honour both, because a machine whose
# user never runs statusline-settings.js never gets the key rewritten — the file
# just sits there in its old shape, and the bar has to keep working.

@test "weekly alias on: 7d group renders" {
  write_settings '{"weekly":"on"}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[7d "* ]]
  [[ "$output" == *"45%"* ]]
}

@test "weekly alias off: no 7d group even with seven_day in the input" {
  write_settings '{"weekly":"off"}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" != *"[7d"* ]]
}

@test "weekly alias as a boolean (the schema shape) is honoured too" {
  write_settings '{"weekly":true}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[7d "* ]]
}

@test "canonical sections.seven_day beats the weekly alias when both are present" {
  write_settings '{"weekly":"on","sections":{"seven_day":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" != *"[7d"* ]]
}

@test "a garbage weekly value falls back to the default, not to on" {
  write_settings '{"weekly":"yes"}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" != *"[7d"* ]]
}

@test "no settings file: weekly defaults to off" {
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" != *"[7d"* ]]
}

@test "style verbose: effort renders as a label" {
  write_settings '{"style":"verbose"}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"

  [ "$status" -eq 0 ]
  [[ "$output" == *"effort:high"* ]]
}

@test "style compact: effort renders as the brain badge, not a label" {
  write_settings '{"style":"compact"}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"

  [ "$status" -eq 0 ]
  [[ "$output" == *"🧠▆"* ]]
  [[ "$output" != *"effort:"* ]]
}

# Regression guard for the dead settings read: a jq syntax error made the query
# itself fail, and 2>/dev/null swallowed it, so weekly/style/badge were silently
# never read while the suite stayed green. Silent degradation must apply to a bad
# FILE only — it must never be able to hide a broken QUERY. A malformed file has
# to land on the defaults AND leave no jq diagnostic anywhere in the output.
@test "malformed settings JSON: silent fallback to defaults, no error text leaks" {
  write_settings 'not json {{{'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"effort\":{\"level\":\"high\"},\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  # Defaults: weekly off, style compact.
  [[ "$output" != *"[7d"* ]]
  [[ "$output" == *"🧠▆"* ]]
  # bats merges stderr into $output, so a leaked diagnostic would show up here.
  [[ "$output" != *"jq:"* ]]
  [[ "$output" != *"error"* ]]
  [[ "$output" != *"Error"* ]]
}

# /statusline-options folds case on the way IN and stores the canonical spelling,
# so the renderer never has to. This pins the other half of that contract: a
# hand-edited non-canonical value is not honoured here either. Both readers
# degrading it to the same default is what keeps them agreeing — a renderer that
# quietly accepted "VERBOSE" would render verbose while /statusline-options
# reported compact.
@test "a non-canonical stored style is not folded: it degrades to the default" {
  write_settings '{"style":"VERBOSE"}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"

  [ "$status" -eq 0 ]
  [[ "$output" == *"🧠▆"* ]]
  [[ "$output" != *"effort:high"* ]]
}

@test "legacy .statusline-style verbose applies when .statusline-settings is absent" {
  printf 'verbose\n' > "$CLAUDE_CONFIG_DIR/.statusline-style"
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"

  [ "$status" -eq 0 ]
  [[ "$output" == *"effort:high"* ]]
}

@test "legacy .statusline-style is ignored once .statusline-settings exists" {
  printf 'verbose\n' > "$CLAUDE_CONFIG_DIR/.statusline-style"
  write_settings '{"style":"compact"}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"

  [ "$status" -eq 0 ]
  [[ "$output" == *"🧠▆"* ]]
  [[ "$output" != *"effort:high"* ]]
}

# --- Advisor indicator --------------------------------------------------------
#
# The advisor is read from settings.json in the resolved config dir. With
# CLAUDE_CONFIG_DIR set it must read that profile's settings.json, never HOME's.

@test "advisor reads the CLAUDE_CONFIG_DIR profile settings.json" {
  printf '{"advisorModel":"opus"}' > "$CLAUDE_CONFIG_DIR/settings.json"
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"advisor:opus"* ]]
}

# Negative: the advisor lives only in HOME while CLAUDE_CONFIG_DIR points at a
# profile without one — it must not leak in. Proves the read is dir-scoped.
@test "advisor in HOME does not leak when CLAUDE_CONFIG_DIR is a different profile" {
  mkdir -p "$HOME/.claude"
  printf '{"advisorModel":"sonnet"}' > "$HOME/.claude/settings.json"
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" != *"advisor:"* ]]
}

# --- Badge precedence ---------------------------------------------------------

@test "badge key wins over statusline-badge.txt" {
  write_settings '{"badge":"FROMJSON "}'
  printf 'FROMTXT ' > "$CLAUDE_CONFIG_DIR/statusline-badge.txt"
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"FROMJSON"* ]]
  [[ "$output" != *"FROMTXT"* ]]
}

# An explicitly empty badge is not "set": it must fall through to the file rather
# than mask it, otherwise clearing the key would blank a working badge.
@test "empty badge key falls through to statusline-badge.txt" {
  write_settings '{"badge":""}'
  printf 'FROMTXT ' > "$CLAUDE_CONFIG_DIR/statusline-badge.txt"
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"FROMTXT"* ]]
}

@test "absent badge key falls back to statusline-badge.txt" {
  write_settings '{"style":"compact"}'
  printf 'FROMTXT ' > "$CLAUDE_CONFIG_DIR/statusline-badge.txt"
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"FROMTXT"* ]]
}

@test "badge key renders with no statusline-badge.txt present" {
  write_settings '{"badge":"X "}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "X ["* ]]
}

@test "no badge anywhere: line 1 starts at the model bracket, no stray escapes" {
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "["* ]]
}

# The badge is interpolated into the printf FORMAT string, so both an escape
# sequence already holding real ESC bytes and the literal-backslash \x1b form
# that create-statusline-badge.sh actually writes must reach the terminal as a
# real ESC byte — never as visible "\x1b[" text.
@test "badge with real ESC bytes round-trips as a real ESC byte" {
  # \u001b is the JSON escape for ESC: jq decodes it to a real 0x1b byte
  # in the badge value. Written this way rather than as a raw ESC byte in
  # this file because a bare control byte inside a JSON string is invalid
  # JSON (jq rejects it), and invisible bytes in test sources are their own
  # hazard.
  write_settings '{"badge":"\u001b[44mB\u001b[0m "}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e[44m'* ]]
  [[ "$output" != *'\x1b['* ]]
}

@test "badge with literal-backslash \\x1b escapes renders as a real ESC byte" {
  # What create-statusline-badge.sh writes: backslash-x-1-b as plain characters.
  write_settings '{"badge":"\\x1b[44mB\\x1b[0m "}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e[44m'* ]]
  [[ "$output" != *'\x1b['* ]]
}

# --- 7d group semantics -------------------------------------------------------

@test "7d reset marker ceils: 2d23h out renders 3d, not 2d" {
  write_settings '{"weekly":"on"}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in $((2 * 86400 + 82800)))}}")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"↻3d"* ]]
  [[ "$output" != *"↻2d"* ]]
}

@test "7d reset in the past: bar and percentage survive, reset marker dropped" {
  write_settings '{"weekly":"on"}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in -86400)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[7d "* ]]
  [[ "$output" == *"45%"* ]]
  [[ "$output" != *"↻"* ]]
  # Group still closes on its own reset — no dangling SGR left behind.
  [[ "$output" == *$'\e[2;37m]\e[0m'* ]]
}

@test "7d reset absent: bar and percentage survive, reset marker dropped" {
  write_settings '{"weekly":"on"}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"rate_limits":{"seven_day":{"used_percentage":45}}')"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[7d "* ]]
  [[ "$output" == *"45%"* ]]
  [[ "$output" != *"↻"* ]]
  [[ "$output" == *$'\e[2;37m]\e[0m'* ]]
}

@test "7d reset non-numeric: bar and percentage survive, reset marker dropped" {
  write_settings '{"weekly":"on"}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"rate_limits":{"seven_day":{"used_percentage":45,"resets_at":"tomorrow"}}')"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[7d "* ]]
  [[ "$output" == *"45%"* ]]
  [[ "$output" != *"↻"* ]]
  [[ "$output" == *$'\e[2;37m]\e[0m'* ]]
}

@test "weekly on but no seven_day in the input: no 7d group at all" {
  write_settings '{"weekly":"on"}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" != *"[7d"* ]]
}

# --- Section gates ------------------------------------------------------------
#
# Every sections.* key gates one renderable group. Each test drives the section
# ON (or relies on its default) to prove the fixture really produces the group,
# then OFF to prove it vanishes — a gate test that only checks the OFF case
# passes just as well when the fixture was never rendering anything.
#
# Absence of a group is asserted on a byte pattern unique to it, and line 1 is
# additionally checked for the double space a naively-removed group leaves.

# Line 1 must never contain a run of two spaces: every group carries its own
# leading space, so a group that "renders empty" instead of vanishing shows up
# here rather than as a wrong-looking-but-passing assertion.
refute_double_space() {
  [[ "${lines[0]}" != *"  "* ]]
}

@test "sections.context false: bare [Model], no bar, no percentage, no window" {
  run bash "$SCRIPT" <<< "$(statusline_input)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"42%"* ]]
  [[ "$output" == *"/ 200K"* ]]

  write_settings '{"sections":{"context":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  # The bracket and the model name survive — the model has no gate of its own.
  [[ "${lines[0]}" == *"[""$(printf '\e[1;33m')""M""$(printf '\e[0m')""]"* ]]
  [[ "$output" != *"42%"* ]]
  [[ "$output" != *"/ 200K"* ]]
  [[ "$output" != *"▒"* ]]
  refute_double_space
}

# The context run carries printf conversions (%d, %s). Dropping the run without
# dropping its arguments makes printf reuse the whole format string and emit the
# line a second time — so assert the line count, not just the missing bar.
@test "sections.context false: line 1 is not duplicated by leftover printf args" {
  write_settings '{"sections":{"context":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" != *"200K"* ]]
}

@test "sections.five_hour false: no 5h group" {
  local input
  input="$(statusline_input ",\"rate_limits\":{\"five_hour\":{\"used_percentage\":71,\"resets_at\":$(epoch_in 3600)}}")"
  run bash "$SCRIPT" <<< "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[5h "* ]]

  write_settings '{"sections":{"five_hour":false}}'
  run bash "$SCRIPT" <<< "$input"

  [ "$status" -eq 0 ]
  [[ "$output" != *"[5h"* ]]
  refute_double_space
}

@test "sections.advisor false: no advisor marker" {
  printf '{"advisorModel":"opus"}' > "$CLAUDE_CONFIG_DIR/settings.json"
  run bash "$SCRIPT" <<< "$(statusline_input)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"advisor:opus"* ]]

  write_settings '{"sections":{"advisor":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" != *"advisor"* ]]
  refute_double_space
}

@test "sections.effort false: no effort indicator in either style" {
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"🧠"* ]]

  write_settings '{"sections":{"effort":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"
  [ "$status" -eq 0 ]
  [[ "$output" != *"🧠"* ]]
  refute_double_space

  # The gate must win over verbose too, not just over the badge form.
  write_settings '{"style":"verbose","sections":{"effort":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"
  [ "$status" -eq 0 ]
  [[ "$output" != *"effort:"* ]]
  [[ "$output" != *"🧠"* ]]
}

@test "sections.caveman false: no caveman indicator" {
  printf 'full' > "$CLAUDE_CONFIG_DIR/.caveman-active"
  run bash "$SCRIPT" <<< "$(statusline_input)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"🪨"* ]]

  write_settings '{"sections":{"caveman":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" != *"🪨"* ]]
  refute_double_space
}

@test "sections.ponytail false: no ponytail indicator" {
  printf 'full' > "$CLAUDE_CONFIG_DIR/.ponytail-active"
  run bash "$SCRIPT" <<< "$(statusline_input)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"🤓"* ]]

  write_settings '{"sections":{"ponytail":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" != *"🤓"* ]]
  refute_double_space
}

@test "sections.git false: no git group, project name survives" {
  init_repo
  run bash "$SCRIPT" <<< "$(statusline_input)"
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *"main"* ]]

  write_settings '{"sections":{"git":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" != *"main"* ]]
  # The project name is not part of the git group and must still render.
  [[ "${lines[1]}" == *"work"* ]]
  [[ "${lines[1]}" != *"  "* ]]
}

@test "sections.git false: no worktree marker either" {
  init_repo
  local input
  input="$(statusline_input ',"worktree":{"name":"wt","branch":"feat","original_branch":"main"}')"
  run bash "$SCRIPT" <<< "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wt"* ]]

  # The worktree marker hangs off the git group; gating git must take it along.
  write_settings '{"sections":{"git":false}}'
  run bash "$SCRIPT" <<< "$input"
  [ "$status" -eq 0 ]
  [[ "$output" != *"feat"* ]]
}

@test "sections.session_start_date false: no clock group" {
  local transcript="$TMP/transcript.jsonl"
  printf '{}\n' > "$transcript"
  local input
  input="$(statusline_input ",\"transcript_path\":\"$transcript\"")"
  run bash "$SCRIPT" <<< "$input"
  [ "$status" -eq 0 ]
  # Guard the premise: birth time is filesystem-dependent, and without it the
  # clock group never renders and the OFF assertion below proves nothing.
  [[ "${lines[1]}" == *$'\xef\x80\x97'* ]] || skip "filesystem reports no birth time"

  write_settings '{"sections":{"session_start_date":false}}'
  run bash "$SCRIPT" <<< "$input"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" != *$'\xef\x80\x97'* ]]
  [[ "${lines[1]}" != *"  "* ]]
}

@test "all sections off: line 1 is badge-free [Model] + folder, line 2 the project" {
  init_repo
  write_settings '{"sections":{"context":false,"five_hour":false,"seven_day":false,"advisor":false,"effort":false,"caveman":false,"ponytail":false,"git":false,"session_start_date":false,"agent":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"agent":{"name":"sub"},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":71}}')"

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  refute_double_space
  [[ "${lines[1]}" != *"  "* ]]
  [[ "${lines[0]}" == "["* ]]
  [[ "$output" != *"[5h"* ]]
  [[ "$output" != *"🧠"* ]]
  [[ "$output" != *"sub"* ]]
  [[ "$output" != *"main"* ]]
}

@test "sections default on: an empty sections object changes nothing" {
  init_repo
  printf '{"advisorModel":"opus"}' > "$CLAUDE_CONFIG_DIR/settings.json"
  write_settings '{"sections":{}}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"

  [ "$status" -eq 0 ]
  [[ "$output" == *"42%"* ]]
  [[ "$output" == *"advisor:opus"* ]]
  [[ "$output" == *"🧠"* ]]
  [[ "${lines[1]}" == *"main"* ]]
  # ...except seven_day, the one section that defaults off.
  [[ "$output" != *"[7d"* ]]
}

@test "a non-boolean section value falls back to its default" {
  write_settings '{"sections":{"context":"false"}}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  # The string "false" is not the boolean false: garbage degrades to the default
  # (on) rather than silently hiding a section.
  [[ "$output" == *"42%"* ]]
}

# --- sections.agent -----------------------------------------------------------

@test "sections.agent default: the agent label renders when the input carries one" {
  run bash "$SCRIPT" <<< "$(statusline_input ',"agent":{"name":"dotfiles-maintainer"}')"

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"dotfiles-maintainer"* ]]
}

@test "sections.agent true: the agent label renders" {
  write_settings '{"sections":{"agent":true}}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"agent":{"name":"dotfiles-maintainer"}')"

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"dotfiles-maintainer"* ]]
}

@test "sections.agent false: no agent label even when the input carries one" {
  write_settings '{"sections":{"agent":false}}'
  run bash "$SCRIPT" <<< "$(statusline_input ',"agent":{"name":"dotfiles-maintainer"}')"

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"dotfiles-maintainer"* ]]
  # The label sits at the head of line 1, so a botched gate shows up as a
  # leading space rather than as leftover text.
  [[ "${lines[0]}" == "["* ]]
}

@test "sections.agent true with no agent in the input: nothing to show, no stray space" {
  write_settings '{"sections":{"agent":true}}'
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "["* ]]
}

# --- Git status icons ---------------------------------------------------------

@test "untracked only: green plus_square_o with the right count, no staged icon" {
  init_repo
  echo "a" > "$WORKDIR/untracked.txt"
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[32m\xef\x86\x96 1\e[0m'* ]]
  [[ "${lines[1]}" != *$'\xef\x81\x86'* ]]
}

@test "staged new file: light green check_square_o with the right count" {
  init_repo
  echo "a" > "$WORKDIR/staged.txt"
  git -C "$WORKDIR" add staged.txt
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[38;5;120m\xef\x81\x86 1\e[0m'* ]]
  [[ "${lines[1]}" != *$'\xef\x86\x96'* ]]
}

@test "untracked and staged together: both render, staged before untracked" {
  init_repo
  echo "a" > "$WORKDIR/staged.txt"
  git -C "$WORKDIR" add staged.txt
  echo "b" > "$WORKDIR/untracked.txt"
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[38;5;120m\xef\x81\x86 1\e[0m \e[32m\xef\x86\x96 1\e[0m'* ]]
}

@test "AM (staged then modified): still counts as staged" {
  init_repo
  echo "a" > "$WORKDIR/f.txt"
  git -C "$WORKDIR" add f.txt
  echo "b" > "$WORKDIR/f.txt"
  # Guard the premise: this is only meaningful if git really reports AM.
  [[ "$(git -C "$WORKDIR" status --porcelain)" == "AM "* ]]

  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[38;5;120m\xef\x81\x86 1\e[0m'* ]]
}

@test "clean tree: check mark renders" {
  init_repo
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[32m\xe2\x9c\x93\e[0m'* ]]
}

@test "clean tree: neither git-status square icon renders" {
  init_repo
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" != *$'\xef\x81\x86'* ]]
  [[ "$output" != *$'\xef\x86\x96'* ]]
}

@test "the retired literal ? untracked marker appears nowhere" {
  init_repo
  echo "a" > "$WORKDIR/untracked.txt"
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e[38;5;229m'* ]]
}

# --- nerd_font ----------------------------------------------------------------
#
# The switch replaces exactly the Private Use Area glyphs (U+E000-U+F8FF), the
# ones that draw as a tofu box without a Nerd Font. ✓ (U+2713) and ↑ (U+2191) are
# ordinary Unicode and are NOT degraded, so the negative assertions below hunt PUA
# bytes specifically rather than "non-ASCII".
#
# Drives one repo into every tracked state at once, so a positional shift in the
# settings parse (the jq list and the matching reads must stay in lockstep) shows
# up as a wrong glyph rather than passing by luck on a single-icon fixture.
dirty_repo_all_states() {
  init_repo
  echo "keep" > "$WORKDIR/mod.txt"
  echo "gone" > "$WORKDIR/del.txt"
  git -C "$WORKDIR" add mod.txt del.txt
  git -C "$WORKDIR" -c user.email=test@example.com -c user.name=Test \
    commit -q -m "base"
  echo "changed" > "$WORKDIR/mod.txt"
  rm "$WORKDIR/del.txt"
  echo "new" > "$WORKDIR/staged.txt"
  git -C "$WORKDIR" add staged.txt
  echo "loose" > "$WORKDIR/untracked.txt"
}

@test "nerd_font=false: git status renders the no-Nerd-Font glyphs" {
  write_settings '{"nerd_font":false}'
  dirty_repo_all_states
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[38;5;120m^ 1\e[0m'* ]]
  [[ "${lines[1]}" == *$'\e[32m+ 1\e[0m'* ]]
  [[ "${lines[1]}" == *$'\e[34m~ 1\e[0m'* ]]
  [[ "${lines[1]}" == *$'\e[31m- 1\e[0m'* ]]
}

@test "nerd_font=false: every fallback glyph is single-width and non-PUA" {
  write_settings '{"nerd_font":false}'
  dirty_repo_all_states
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  # The criterion is not just "not PUA": a fallback in a poorly-covered block (⨣
  # U+2A23, Supplemental Mathematical Operators) would still be tofu for the very
  # users this serves, and a double-width emoji one (➕ U+2795) would break the
  # column alignment. Neither may creep back in.
  [[ "${lines[1]}" != *$'\xe2\xa8\xa3'* ]]  # U+2A23 ⨣
  [[ "${lines[1]}" != *$'\xe2\x9e\x95'* ]]  # U+2795 ➕
  # The retired letter form: the set is symbols, not letters.
  [[ "${lines[1]}" != *$'\e[38;5;120mA 1\e[0m'* ]]
}

@test "nerd_font=false: no Private Use Area bytes anywhere in the git group" {
  write_settings '{"nerd_font":false}'
  dirty_repo_all_states
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" != *$'\xef\x85\xb6'* ]]  # U+F176 ahead
  [[ "${lines[1]}" != *$'\xef\x81\x86'* ]]  # U+F046 staged-new
  [[ "${lines[1]}" != *$'\xef\x86\x96'* ]]  # U+F196 untracked
  [[ "${lines[1]}" != *$'\xef\x81\x84'* ]]  # U+F044 modified
  [[ "${lines[1]}" != *$'\xef\x85\x87'* ]]  # U+F147 deleted
  [[ "${lines[1]}" != *$'\xee\x9c\xa5'* ]]  # U+E725 the group's leading branch icon
  [[ "${lines[1]}" == *"git "* ]]
}

@test "nerd_font=false: ahead keeps ordinary Unicode U+2191 rather than degrading to ASCII" {
  write_settings '{"nerd_font":false}'
  init_repo
  # -u is the point: the ahead count is measured against @{upstream}, so a plain
  # push would leave it unset and the count at 0.
  git init -q --bare "$TMP/bare.git"
  git -C "$WORKDIR" remote add origin "$TMP/bare.git"
  git -C "$WORKDIR" push -q -u origin main
  git -C "$WORKDIR" -c user.email=test@example.com -c user.name=Test \
    commit -q --allow-empty -m "ahead"
  # Guard the premise: without an upstream the ahead count is 0 and this proves nothing.
  [ "$(git -C "$WORKDIR" rev-list --count @{upstream}..HEAD)" = "1" ]

  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[33m\xe2\x86\x91 1\e[0m'* ]]
  [[ "${lines[1]}" != *$'\xef\x85\xb6'* ]]
}

@test "nerd_font=false: clean tree still renders U+2713, which is not a Nerd Font glyph" {
  write_settings '{"nerd_font":false}'
  init_repo
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[32m\xe2\x9c\x93\e[0m'* ]]
}

@test "nerd_font absent: defaults to true, Nerd Font glyphs still render" {
  dirty_repo_all_states
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[38;5;120m\xef\x81\x86 1\e[0m'* ]]
  [[ "${lines[1]}" == *$'\e[32m\xef\x86\x96 1\e[0m'* ]]
  [[ "${lines[1]}" == *$'\e[34m\xef\x81\x84 1\e[0m'* ]]
  [[ "${lines[1]}" == *$'\e[31m\xef\x85\x87 1\e[0m'* ]]
  [[ "${lines[1]}" == *$'\xee\x9c\xa5'* ]]
}

@test "nerd_font=true: explicit true renders the Nerd Font glyphs" {
  write_settings '{"nerd_font":true}'
  dirty_repo_all_states
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[38;5;120m\xef\x81\x86 1\e[0m'* ]]
  [[ "${lines[1]}" != *$'\e[38;5;120m^ 1\e[0m'* ]]
}

@test "nerd_font non-boolean: degrades to the default rather than to ASCII" {
  write_settings '{"nerd_font":"false"}'
  dirty_repo_all_states
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[38;5;120m\xef\x81\x86 1\e[0m'* ]]
}

@test "nerd_font=false: the other settings keys still land (no positional shift)" {
  write_settings '{"nerd_font":false,"style":"verbose","sections":{"git":false}}'
  dirty_repo_all_states
  run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"

  [ "$status" -eq 0 ]
  # style=verbose reached its reader
  [[ "$output" == *"effort:high"* ]]
  # sections.git=false reached its reader: the whole git group is gone
  [[ "${lines[1]}" != *"git "* ]]
  [[ "${lines[1]}" != *$'\e[32m+ 1\e[0m'* ]]
}

# --- Context bar dual-mode ----------------------------------------------------
#
# 200K models threshold on used percentage; 1M models threshold on absolute used
# tokens instead. Same palette in both modes.

@test "200K model at 69%: bar and percentage uncoloured" {
  run bash "$SCRIPT" <<< "$(context_input 69 200000)"

  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e[38;5;230m'* ]]
  [[ "$output" != *$'\e[38;5;216m'* ]]
  [[ "$output" != *$'\e[38;5;210m'* ]]
}

@test "200K model at 70%: cream" {
  run bash "$SCRIPT" <<< "$(context_input 70 200000)"

  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e[38;5;230m'* ]]
}

@test "200K model at 80%: light orange" {
  run bash "$SCRIPT" <<< "$(context_input 80 200000)"

  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e[38;5;216m'* ]]
}

@test "200K model at 90%: rose" {
  run bash "$SCRIPT" <<< "$(context_input 90 200000)"

  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e[38;5;210m'* ]]
}

@test "1M model at 19% (190K tokens): uncoloured, on absolute tokens not percentage" {
  run bash "$SCRIPT" <<< "$(context_input 19 1000000)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"/ 1M"* ]]
  [[ "$output" != *$'\e[38;5;230m'* ]]
  [[ "$output" != *$'\e[38;5;216m'* ]]
  [[ "$output" != *$'\e[38;5;210m'* ]]
}

@test "1M model at 20% (200K tokens): cream" {
  run bash "$SCRIPT" <<< "$(context_input 20 1000000)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"/ 1M"* ]]
  [[ "$output" == *$'\e[38;5;230m'* ]]
}

# --- Isolation ----------------------------------------------------------------

# The statusline is read-only: it must never create or write config. HOME points
# into the temp dir for every test, so a stray write would land here rather than
# in the real ~/.claude — assert nothing was created.
@test "statusline writes no config: temp HOME stays free of .claude" {
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude" ]
}

# --- Config-dir precedence ----------------------------------------------------
#
# Precedence: --config-dir > $STATUSLINE_CONFIG_DIR > $CLAUDE_CONFIG_DIR > probe
# ($HOME/.claude, then $USERPROFILE/.claude).
#
# Every level gets a badge naming itself, so the rendered badge names the dir that
# actually won — the assertion is on the resolution, not merely on the script
# surviving. The badge is the signal on purpose: it is the one config value echoed
# back to stdout verbatim, so it maps to a dir with no decoding.
#
# Each test populates EVERY level below the one under test, so a test can only
# pass by preferring the right dir, never by it being the sole candidate. The
# negative assertions are the point: without them a resolver returning the last
# candidate standing would pass all of these.
#
# setup() does not unset STATUSLINE_CONFIG_DIR (nothing else reads it), so the
# probe tests below clear it explicitly via `env -u` rather than trusting ambient.
setup_precedence_dirs() {
  CLI_DIR="$TMP/cli"
  SL_DIR="$TMP/sl"
  mkdir -p "$CLI_DIR" "$SL_DIR"
  printf 'CLIBDG ' > "$CLI_DIR/statusline-badge.txt"
  printf 'SLBDG '  > "$SL_DIR/statusline-badge.txt"
  printf 'CCBDG '  > "$CLAUDE_CONFIG_DIR/statusline-badge.txt"
  export STATUSLINE_CONFIG_DIR="$SL_DIR"
}

@test "config dir: --config-dir wins over STATUSLINE_CONFIG_DIR and CLAUDE_CONFIG_DIR" {
  setup_precedence_dirs

  run bash "$SCRIPT" --config-dir "$CLI_DIR" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"CLIBDG"* ]]
  [[ "$output" != *"SLBDG"* ]]
  [[ "$output" != *"CCBDG"* ]]
}

# The equals form is a separate branch of the parser from the space-separated
# one, so it earns its own test rather than being assumed equivalent.
@test "config dir: --config-dir=<path> is equivalent to --config-dir <path>" {
  setup_precedence_dirs

  run bash "$SCRIPT" "--config-dir=$CLI_DIR" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"CLIBDG"* ]]
  [[ "$output" != *"SLBDG"* ]]
  [[ "$output" != *"CCBDG"* ]]
}

@test "config dir: STATUSLINE_CONFIG_DIR wins over CLAUDE_CONFIG_DIR" {
  setup_precedence_dirs

  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"SLBDG"* ]]
  [[ "$output" != *"CCBDG"* ]]
}

# CLAUDE_CONFIG_DIR must still beat the probe: this is the path Claude Code drives
# for every profile, and the one the refactor could most easily have inverted.
@test "config dir: CLAUDE_CONFIG_DIR wins over the HOME probe" {
  setup_precedence_dirs
  unset STATUSLINE_CONFIG_DIR
  mkdir -p "$HOME/.claude"
  printf 'HOMEBDG ' > "$HOME/.claude/statusline-badge.txt"

  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"CCBDG"* ]]
  [[ "$output" != *"HOMEBDG"* ]]
}

# The default: no arg, no env, so resolution walks the probe cascade to
# $HOME/.claude — what Claude Code hits on a machine with no CLAUDE_CONFIG_DIR.
# This is the case the byte-parity gate covers, pinned here as a unit test too.
@test "config dir: no arg and no env resolves through the HOME probe" {
  mkdir -p "$HOME/.claude"
  printf 'HOMEBDG ' > "$HOME/.claude/statusline-badge.txt"

  run env -u CLAUDE_CONFIG_DIR -u STATUSLINE_CONFIG_DIR bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"HOMEBDG"* ]]
}

# The probe's second rung: with $HOME/.claude carrying no badge, resolution falls
# through to $USERPROFILE/.claude. setup() unsets USERPROFILE, so this is the only
# test where that branch can fire.
@test "config dir: probe falls through to USERPROFILE when HOME lacks the file" {
  mkdir -p "$HOME/.claude" "$TMP/userprofile/.claude"
  printf 'UPBDG ' > "$TMP/userprofile/.claude/statusline-badge.txt"

  run env -u CLAUDE_CONFIG_DIR -u STATUSLINE_CONFIG_DIR USERPROFILE="$TMP/userprofile" \
    bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"UPBDG"* ]]
}

# An explicit dir short-circuits the probe outright: a profile with no badge must
# read as "no badge", never quietly inherit HOME's. This is what makes an explicit
# dir mean "this profile" rather than "start searching here".
@test "config dir: explicit dir without the file does not fall through to HOME" {
  mkdir -p "$HOME/.claude"
  printf 'HOMEBDG ' > "$HOME/.claude/statusline-badge.txt"

  run bash "$SCRIPT" --config-dir "$CLAUDE_CONFIG_DIR" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" != *"HOMEBDG"* ]]
}

# Each call site probes for its own file, so files in different dirs must resolve
# independently — collapsing the five into one shared dir is the regression this
# guards. The caveman flag lives only in HOME, the badge only in USERPROFILE: both
# must render, which no single resolved dir could achieve.
@test "config dir: probe resolves per-file, not once for all call sites" {
  mkdir -p "$HOME/.claude" "$TMP/userprofile/.claude"
  printf 'full' > "$HOME/.claude/.caveman-active"
  printf 'UPBDG ' > "$TMP/userprofile/.claude/statusline-badge.txt"

  run env -u CLAUDE_CONFIG_DIR -u STATUSLINE_CONFIG_DIR USERPROFILE="$TMP/userprofile" \
    bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"UPBDG"* ]]
  [[ "$output" == *"🪨▄"* ]]
}

# --- Windows: jq.exe writes CRLF ----------------------------------------------
#
# jq on Windows opens stdout in text mode, so every line it emits ends CRLF. The
# single-value reads elsewhere survive it because MSYS bash strips one trailing CR
# off a command substitution, but the settings block is read with `read`, which
# does not — and there the CR is not cosmetic: an absent section key arrives as
# "\r" rather than "", which is non-empty, so section_enabled never reaches its
# default and evaluates the key as false. Every section switches itself off the
# moment a .statusline-settings file exists.
#
# The shim CRLFs only the settings read, not every jq call: on a POSIX host the
# other call sites have no MSYS strip behind them, so a global shim would fail for
# a reason this test is not about.
crlf_jq_shim() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/jq" <<SHIM
#!/bin/bash
for _arg in "\$@"; do
  case "\$_arg" in
    *.statusline-settings) $(command -v jq) "\$@" | sed 's/\$/\r/'; exit ;;
  esac
done
exec $(command -v jq) "\$@"
SHIM
  chmod +x "$TMP/bin/jq"
}

@test "settings: CRLF from jq does not switch every section off" {
  crlf_jq_shim
  write_settings '{"style":"verbose"}'

  PATH="$TMP/bin:$PATH" run bash "$SCRIPT" <<< "$(statusline_input ',"effort":{"level":"high"}')"

  [ "$status" -eq 0 ]
  # style reached its reader despite the CR...
  [[ "$output" == *"effort:high"* ]]
  # ...and sections.context, absent from the file, still defaults to on.
  [[ "$output" == *"42%"* ]]
}

@test "settings: CRLF from jq does not leave a stray CR in the badge" {
  crlf_jq_shim
  write_settings '{"badge":"BDG "}'

  PATH="$TMP/bin:$PATH" run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"BDG "* ]]
  [[ "$output" != *$'\r'* ]]
}

# Unknown arguments are ignored rather than fatal: a future Claude Code passing a
# new flag must not cost the user their whole statusline over something cosmetic.
# Asserting on the context run, not the model name — the name is colour-wrapped,
# so the bracket and the "M" are never adjacent bytes.
@test "config dir: unknown arguments are ignored, not fatal" {
  run bash "$SCRIPT" --some-future-flag <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"42%"* ]]
  [[ "$output" == *"/ 200K"* ]]
}

# --- Git locks ----------------------------------------------------------------

# `git status` takes .git/index.lock to refresh the index, and this script runs on
# every render against whatever repo the user is in — so a render can race, and
# fail, the user's own `git pull`. GIT_OPTIONAL_LOCKS=0 opts out. Asserted on the
# environment git actually receives, via a PATH shim, rather than on the source
# text: an `export` the child never inherits would pass a grep and fail in life.
@test "git: child git processes run with GIT_OPTIONAL_LOCKS=0" {
  init_repo
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/git" <<SHIM
#!/bin/bash
printf '%s\n' "\${GIT_OPTIONAL_LOCKS-unset}" >> "$TMP/locks.log"
exec /usr/bin/env -u PATH PATH="$PATH" $(command -v git) "\$@"
SHIM
  chmod +x "$TMP/bin/git"

  PATH="$TMP/bin:$PATH" run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [ -s "$TMP/locks.log" ]
  # Every invocation, not just the first: one unguarded call is enough to race.
  ! grep -qv '^0$' "$TMP/locks.log"
}

# --- Windows paths reaching a POSIX renderer ----------------------------------
#
# Claude Code running natively on Windows sends cwd as "D:\git\project" even when
# statusLine.command shells into WSL to render. Under WSL that path does not
# exist — /mnt/d/git/project is the same directory under the only name Linux
# knows — so `git -C` fails, project_root and git_branch come out empty, and the
# entire line-2 git group vanishes while sections.git still reads as on.
#
# Driven through a wslpath shim rather than a real WSL mount so the test means the
# same thing on every platform: the drive letter is one that cannot resolve, which
# is what sends the path down the translation branch, and the shim maps it onto
# this test's actual repo. Asserting the git group *renders* is the point — the
# folder name alone would pass on MSYS even with the fix reverted, since basename
# there already splits backslashes.
@test "windows cwd: an unresolvable drive-letter path is translated, git group survives" {
  init_repo
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/wslpath" <<SHIM
#!/bin/bash
printf '%s\n' "$WORKDIR"
SHIM
  chmod +x "$TMP/bin/wslpath"

  PATH="$TMP/bin:$PATH" run bash "$SCRIPT" <<< '{"model":{"display_name":"M"},"cwd":"X:\\nope\\repo","context_window":{"used_percentage":42,"context_window_size":200000}}'

  [ "$status" -eq 0 ]
  [[ "$output" == *"main"* ]]
  [[ "$output" == *"$(basename "$WORKDIR")"* ]]
  [[ "$output" != *'X:'* ]]
}
