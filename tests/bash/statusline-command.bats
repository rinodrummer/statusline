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

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../.claude/statusline-command.sh"
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

@test "weekly on: 7d group renders when seven_day is in the input" {
  write_settings '{"weekly":"on"}'
  run bash "$SCRIPT" <<< "$(statusline_input ",\"rate_limits\":{\"seven_day\":{\"used_percentage\":45,\"resets_at\":$(epoch_in 200000)}}")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[7d "* ]]
  [[ "$output" == *"45%"* ]]
}

@test "weekly off: no 7d group even with seven_day in the input" {
  write_settings '{"weekly":"off"}'
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

@test "untracked and staged together: both render, untracked before staged" {
  init_repo
  echo "a" > "$WORKDIR/staged.txt"
  git -C "$WORKDIR" add staged.txt
  echo "b" > "$WORKDIR/untracked.txt"
  run bash "$SCRIPT" <<< "$(statusline_input)"

  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *$'\e[32m\xef\x86\x96 1\e[0m \e[38;5;120m\xef\x81\x86 1\e[0m'* ]]
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

@test "1M model at 19% (190K tokens): uncoloured — absolute tokens, not percentage" {
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
