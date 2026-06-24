---
description: Set or toggle the statusline style (compact/verbose)
allowed-tools: Bash(node:*)
---

Control the statusline style flag
(`$CLAUDE_CONFIG_DIR/.statusline-style`, default `~/.claude/.statusline-style`).
Contents `verbose` = extended/verbose mode; contents `compact` (or absent) = compact.

Optional argument `$ARGUMENTS`: `compact` or `verbose`. If omitted, toggle.

Do this:

1. Run `node ~/.claude/scripts/claude/statusline-style.js $ARGUMENTS`.
2. Report the new state from the script output (extended ON or compact).
