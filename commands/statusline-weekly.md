---
description: Show or hide the Claude.ai weekly (7-day) rate-limit bar — shim for /statusline-options
allowed-tools: Bash(node:*)
---

Shim kept for muscle memory and for the `statusline-weekly` shell alias.
`/statusline-options weekly=true|false` is the canonical path, and can set this
alongside every other option in one go.

Controls the Claude.ai 7-day (weekly) rate-limit bar in the statusline, stored in
the statusline settings file (`$CLAUDE_CONFIG_DIR/.statusline-settings`, default
`~/.claude/.statusline-settings`) under `sections.seven_day`. `on` = show the
weekly bar; `off` (the default) = hide it.

Optional argument `$ARGUMENTS`: `on` or `off`. If omitted, toggle.

Do this:

1. Run `node ~/.claude/scripts/claude/statusline-settings.js weekly $ARGUMENTS`.
2. Report the new state from the script output (weekly ON or OFF).
