#!/usr/bin/env bats
#
# Tests for install.sh — specifically the statusLine.command string it writes,
# which is the one part of the installer that is platform-dependent and the one
# part whose breakage is silent: a wrong command string installs cleanly, reports
# success, and renders nothing.
#
# Isolation: every test installs into its own mktemp -d, so the real ~/.claude is
# never touched. HOME is repointed as well, since the default --config-dir is
# derived from it.
#
# The Windows branch is exercised two ways. `uname` is stubbed on PATH to drive
# the branch selection anywhere, and the bash.exe probe — which can only be
# meaningful against a real MSYS layout — runs unskipped only when the suite is
# itself running under one.

setup() {
  INSTALLER="${BATS_TEST_DIRNAME}/../../install.sh"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  CONFIG="$TMP/config"
  STUB_BIN="$TMP/stub-bin"
  mkdir -p "$HOME" "$STUB_BIN"
}

teardown() {
  rm -rf "$TMP"
}

# Put a fake `uname -s` ahead of the real one, so both platform branches are
# reachable from whichever platform is running the suite.
stub_uname() {
  cat > "$STUB_BIN/uname" <<EOF
#!/bin/bash
printf '%s\n' "$1"
EOF
  chmod +x "$STUB_BIN/uname"
  PATH="$STUB_BIN:$PATH"
}

status_command_of() {
  jq -r '.statusLine.command' "$1/settings.json"
}

running_on_windows_bash() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

@test "non-Windows: wires the POSIX spelling" {
  stub_uname Linux
  run bash "$INSTALLER" --config-dir "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$(status_command_of "$CONFIG")" = "bash $CONFIG/statusline-command.sh" ]
}

@test "non-Windows: shell-quotes a config dir containing a space" {
  stub_uname Linux
  spaced="$TMP/two words"
  run bash "$INSTALLER" --config-dir "$spaced"
  [ "$status" -eq 0 ]
  # printf %q escapes the space rather than quoting the whole path; either way the
  # shell must see one argument, so assert the space is not bare.
  [[ "$(status_command_of "$spaced")" != *"two words"* ]]
  [[ "$(status_command_of "$spaced")" == *"statusline-command.sh"* ]]
}

@test "Windows: names bash.exe by absolute Windows path, not the bare word" {
  running_on_windows_bash || skip "needs a real MSYS/Cygwin layout to probe"
  run bash "$INSTALLER" --config-dir "$CONFIG"
  [ "$status" -eq 0 ]
  cmd="$(status_command_of "$CONFIG")"
  # A bare `bash` here is the bug this branch exists for: on native Windows it
  # resolves to the WSL launcher, not to the shell that just ran the installer.
  [[ "$cmd" != bash\ * ]]
  [[ "$cmd" == \"[A-Za-z]:/*bash.exe\"\ \"[A-Za-z]:/*statusline-command.sh\" ]]
}

@test "Windows: the wired command actually renders" {
  running_on_windows_bash || skip "needs a real MSYS/Cygwin layout to probe"
  run bash "$INSTALLER" --config-dir "$CONFIG"
  [ "$status" -eq 0 ]
  cmd="$(status_command_of "$CONFIG")"
  # Round-trip through a shell: whatever quoting the installer chose has to survive
  # being handed to one, which is all Claude Code does with this string.
  run bash -c "printf '%s' '{\"model\":{\"display_name\":\"M\"},\"cwd\":\".\"}' | $cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"M"* ]]
}

@test "re-running over the previous POSIX spelling updates it in place" {
  # The upgrade path for anyone who installed before the Windows branch existed:
  # the old command still matches the \"ours\" pattern, so it is rewritten rather
  # than treated as a stranger's statusline and skipped.
  mkdir -p "$CONFIG"
  jq -n --arg c "bash $CONFIG/statusline-command.sh" \
    '{statusLine: {type: "command", command: $c}, otherKey: "kept"}' \
    > "$CONFIG/settings.json"

  stub_uname MINGW64_NT-10.0
  run bash "$INSTALLER" --config-dir "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" != *"already has a statusLine"* ]]
  [ "$(jq -r '.otherKey' "$CONFIG/settings.json")" = "kept" ]
}

@test "an unrelated statusline is still left alone" {
  mkdir -p "$CONFIG"
  jq -n '{statusLine: {type: "command", command: "oh-my-posh print primary"}}' \
    > "$CONFIG/settings.json"

  stub_uname Linux
  run bash "$INSTALLER" --config-dir "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already has a statusLine"* ]]
  [ "$(status_command_of "$CONFIG")" = "oh-my-posh print primary" ]
}
