---
description: Set or toggle the statusline style (compact/verbose) — shim for /statusline-options
allowed-tools: Bash(node:*)
---

Shim kept for muscle memory and for the `statusline-style` shell alias.
`/statusline-options style=compact|verbose` is the canonical path, and can set
this alongside every other option in one go.

Controls the statusline style in the statusline settings file
(`$CLAUDE_CONFIG_DIR/.statusline-settings`, default `~/.claude/.statusline-settings`).
`style` `verbose` = extended/verbose mode; `compact` (or absent) = compact.

Optional argument `$ARGUMENTS`: `compact` or `verbose`. If omitted, toggle.

Do this:

1. Run `node ~/.claude/scripts/claude/statusline-settings.js style $ARGUMENTS`.
2. Report the new state from the script output (extended ON or compact).
