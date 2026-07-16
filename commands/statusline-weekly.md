---
description: Show or hide the Claude.ai weekly (7-day) rate-limit bar in the statusline
allowed-tools: Bash(node:*)
---

Control the Claude.ai 7-day (weekly) rate-limit bar in the statusline, stored in
the statusline settings file (`$CLAUDE_CONFIG_DIR/.statusline-settings`, default
`~/.claude/.statusline-settings`). `weekly` `on` = show the weekly bar; `off` (the
default) = hide it.

Optional argument `$ARGUMENTS`: `on` or `off`. If omitted, toggle.

Do this:

1. Run `node ~/.claude/scripts/claude/statusline-settings.js weekly $ARGUMENTS`.
2. Report the new state from the script output (weekly ON or OFF).
