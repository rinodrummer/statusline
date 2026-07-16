---
description: Read or set the statusline options (style, sections, agent mode, badge)
allowed-tools: Bash(node:*)
---

The canonical statusline configuration command. Reads and writes the statusline
settings file (`$CLAUDE_CONFIG_DIR/.statusline-settings`, default
`~/.claude/.statusline-settings`).

`$ARGUMENTS` is passed through verbatim. Supported forms:

- *(empty)* — print the current effective configuration
- `--json` — print it as JSON
- `<key>=<value> ...` — set any number of options in one go
- `--reset` — restore every option to its default (the badge is kept)
- `--reset=<key>,<key>` — restore only the listed options

Keys, and what they accept:

| Key | Values | Default |
|---|---|---|
| `style` | `compact`, `verbose` | `compact` |
| `agent` | `true`, `false` | `true` |
| `context` | `true`, `false` | `true` |
| `five_hour` | `true`, `false` | `true` |
| `weekly` (= `seven_day`) | `true`, `false` | `false` |
| `advisor` | `true`, `false` | `true` |
| `effort` | `true`, `false` | `true` |
| `caveman` | `true`, `false` | `true` |
| `ponytail` | `true`, `false` | `true` |
| `git` | `true`, `false` | `true` |
| `clock` (= `session_start_date`) | `true`, `false` | `true` |

Booleans accept `true`/`on`/`1` and `false`/`off`/`0`. Values are
case-insensitive (`agent=TRUE`, `style=VERBOSE`) and stored canonically.

Section keys may be spelled with their schema prefix (`sections.git`), which is
what `--reset=sections.git,sections.clock` does. Keys themselves are
case-sensitive. An invalid key or value aborts the whole batch — nothing is
written.

**The badge is shown, not settable.** It appears in the read output and in
`--json`, but `badge=...` and `--reset=badge` are rejected: the badge is profile
identity, written by `create-statusline-badge.sh` during profile setup, not a
toggle like the sections. Plain `--reset` leaves it alone.

Do this:

1. Run `node ~/.claude/scripts/claude/statusline-settings.js options $ARGUMENTS`.
2. Report the configuration (or the new state) from the script output.
