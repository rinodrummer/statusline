# Claude Code Statusline

A two-line statusline for [Claude Code](https://claude.com/claude-code): model and
context usage, rate-limit windows, git state, and session duration.

```
<agent> [Model | ███▒░░ 62% / 200K] [5h ███▓░ 71% ↻18:40] [7d ██▒░░ 45% ↻3d] 📂 my-project + 2 dirs
my-project ( main > +2 ~1) [wt:feature <- main] 🕐 14:30 (1h 12m)
```

## What it renders

**Line 1**

| Group | Shows |
|---|---|
| Agent name | Only for subagents (e.g. `dotfiles-maintainer`). Claude Code populates this for subagents only. |
| `[Model \| bar % / window]` | Model name, context-usage bar, percent used, and context-window size. |
| `[5h ...]` | Claude.ai 5-hour rate-limit window, with a `↻HH:MM` reset clock. Omitted entirely when unavailable (e.g. API-key auth). |
| `[7d ...]` | Claude.ai 7-day rate-limit window, with a `↻Nd` reset marker. **Opt-in** — off by default. |
| Directory | Current folder, plus a `+ N dirs` count for extra workspace roots. |

**Line 2**

| Group | Shows |
|---|---|
| Project | Project name (always rendered). |
| Git | Branch, then status: `↑` ahead, `⊞` untracked, `☑` staged-new, `~` modified, `-` deleted, `✓` clean. Untracked precedes staged, so the pair reads as the `??` → `A` progression across `git add`. |
| Worktree | `[wt:feature <- main]` when in a linked worktree. |
| Clock | Session start time and elapsed duration. |

**Bars.** Each cell carries four sub-levels (`░ ▒ ▓ █`), so a bar resolves to
`width × 4` steps rather than whole cells only.

**Colour ramps.** The context bar escalates by *absolute tokens* on 1M-context
models (≥200K, ≥300K, ≥400K) and by *percentage* on 200K models (≥70%, ≥80%,
≥90%) — same three colours either way, plain below the lowest threshold. A `⚠`
precedes the bar past 200k tokens. The `[5h]` and `[7d]` groups share one ramp:
plain <50%, pale yellow 50–84%, dark orange 85–89%, red ≥90%; brackets and reset
marker take a dimmed variant of the same colour, so each group reads as one
colour with the bar dominant.

## Requirements

| | Needed for |
|---|---|
| **`jq`** | **Hard requirement.** The renderer parses its session JSON with it. Without `jq` there is no statusline. |
| **A Nerd Font terminal** | The icons (folder, branch, clock). Without one they render as tofu boxes. Get one from [nerdfonts.com](https://www.nerdfonts.com/) and select it in your terminal — or set [`nerd_font=false`](#without-a-nerd-font), which falls the **git** icons back to glyphs any font has. |
| `git` | The line-2 git group only. Everything else still renders without it. |
| `node` | The settings helper and slash commands only. The statusline itself renders on its built-in defaults without Node. |
| `bash` | Works on macOS's bash 3.2 — no bash 4+ syntax anywhere. |

**Line endings matter.** This repo ships a `.gitattributes` forcing LF on shell
scripts. If you clone on Windows with `core.autocrlf=true` and lose it, the
renderer dies with `$'\r': command not found` — CRLF is not survivable for a
script Claude Code execs. Keep `.gitattributes`.

## Install

```sh
git clone https://github.com/rinodrummer/statusline.git
cd statusline
./install.sh
```

Then restart Claude Code.

| Flag | Default | Meaning |
|---|---|---|
| `--mode=copy` | ✅ default | Copies the files. The install survives this clone moving or being deleted. |
| `--mode=symlink` | | Links back to this clone, so `git pull` updates the installed statusline. The clone must stay put. |
| `--config-dir <path>` | `~/.claude` | Claude Code config dir to install into. |
| `--force` | | Replace an existing, unrelated statusline. See below. |

The installer is **additive and idempotent**: it writes only the paths below plus
a single `statusLine` key, deletes nothing, and re-running is a no-op. It patches
`settings.json` through `jq`, so your existing keys (model, hooks, permissions)
survive untouched. If `settings.json` doesn't exist it is created; if it exists
but is invalid JSON, the installer refuses rather than overwrite it.

**If you already have a statusline** (oh-my-posh, a script of your own), the
installer will not take it from you: it deploys everything, then warns and skips
only the wiring, printing the `statusLine.command` value to set by hand if you
want it. Re-run with `--force` to replace it. Re-running over a statusline this
installer wrote is not a clobber and needs no flag — it updates in place.

What lands where:

```
$CONFIG_DIR/statusline-command.sh                    # the renderer
$CONFIG_DIR/scripts/claude/statusline-settings.js    # the settings helper
$CONFIG_DIR/commands/statusline-*.md                 # the slash commands
$CONFIG_DIR/settings.json                            # statusLine.command patched in
```

## Configuring it

Settings live in one JSON file, `$CLAUDE_CONFIG_DIR/.statusline-settings`
(default `~/.claude/.statusline-settings`). Its full shape is in
`statusline-settings.schema.json`.

`/statusline-options` is the canonical way to set it:

```
/statusline-options                    # print the current configuration
/statusline-options --json             # print it as JSON
/statusline-options weekly=true        # turn the [7d] group on
/statusline-options style=verbose git=false
/statusline-options --reset            # back to defaults (the badge is kept)
/statusline-options --reset=git,clock  # reset only these
```

Same thing without the slash command:

```sh
node ~/.claude/scripts/claude/statusline-settings.js options weekly=true
```

| Key | Values | Default | What it does |
|---|---|---|---|
| `style` | `compact`, `verbose` | `compact` | `verbose` spells the effort/caveman/ponytail indicators out as labels; `compact` renders them as badges. |
| `nerd_font` | `true`/`false` | `true` | Whether your terminal has a Nerd Font. `false` draws the git icons with glyphs any font has — see [Without a Nerd Font](#without-a-nerd-font). Not a gate: it hides nothing, it only changes how the git group draws. |
| `agent` | `true`/`false` | `true` | The agent label on line 1. |
| `context` | `true`/`false` | `true` | The bar/percent/window run *inside* the model bracket. `false` still renders a bare `[Model]` — the model name has no gate of its own. |
| `five_hour` | `true`/`false` | `true` | The `[5h]` group. |
| `weekly` (= `seven_day`) | `true`/`false` | **`false`** | The `[7d]` group. The one section defaulting off. |
| `advisor` | `true`/`false` | `true` | The `[advisor:<model>]` marker. |
| `effort` | `true`/`false` | `true` | The effort/thinking indicator. |
| `caveman` | `true`/`false` | `true` | The caveman-mode indicator. |
| `ponytail` | `true`/`false` | `true` | The ponytail-mode indicator. |
| `git` | `true`/`false` | `true` | The line-2 git group. The project name is not part of it and always renders. |
| `clock` (= `session_start_date`) | `true`/`false` | `true` | The line-2 clock group: icon, start time, duration. |

Booleans accept `true`/`on`/`1` and `false`/`off`/`0`, case-insensitively
(`agent=TRUE`, `style=VERBOSE`), and are stored canonically. An invalid key or
value aborts the whole batch — nothing is written. A section set to `false` is
omitted with no separator or double space left behind.

Every key except `style` and `nerd_font` is a section: it gates one renderable
group, and `false` omits it. `style` and `nerd_font` gate nothing — they change
how things draw, not whether they draw.

A missing, unreadable, or malformed settings file degrades silently to the
defaults above. That is deliberate: a bad config file must still render a
statusline rather than break your prompt. Nothing validates the schema at
runtime.

### Without a Nerd Font

The git status icons are [Nerd Font](https://www.nerdfonts.com/) glyphs, which
live in Unicode's Private Use Area. Without the font installed they render as
tofu boxes (`□`). If you cannot install one, turn the icons off:

```sh
/statusline-options nerd_font=false
```

The git group then draws with characters any ordinary font has:

The Nerd Font column is given as codepoints on purpose — printed here as glyphs,
it would be tofu boxes for exactly the readers this section is for.

| | `nerd_font=true` | `nerd_font=false` |
|---|---|---|
| branch (leads the group) | U+E725 | `git` |
| ahead | U+F176 | `↑` |
| staged (new file) | U+F046 | `^` |
| untracked | U+F196 | `+` |
| modified | U+F044 | `~` |
| deleted | U+F147 | `-` |
| clean | `✓` U+2713 | `✓` (unchanged) |

Colours are identical in both modes — only the glyph changes. The table is in
render order; read `+` → `^` → `↑` and they describe the lifecycle of a change:
`+` is new, `^` is staged (rising), `↑` is already gone up.

Only the Private Use Area glyphs are swapped, not everything non-ASCII: `✓`
(U+2713) and `↑` (U+2191) are ordinary Unicode that renders without a Nerd Font,
so `✓` is the same in both modes and `↑` is a real arrow rather than a caret.

There is no auto-detection, and that is deliberate: a terminal cannot be asked
which fonts it has, and nothing in `TERM_PROGRAM` or `WT_SESSION` distinguishes a
real glyph from a tofu box. So you declare it. The default is `true`, which keeps
the icons for everyone who never touches this.

This setting covers the **git** icons. The context-warning and clock icons are
Nerd Font glyphs too and are not currently affected by it.

### The badge

A badge is an arbitrary (ANSI-capable) string prepended to line 1 — profile
identity, useful to tell two Claude Code configs apart at a glance. It is
**shown by `options` but not settable through it**:

```sh
node ~/.claude/scripts/claude/statusline-settings.js badge "PROD"
node ~/.claude/scripts/claude/statusline-settings.js badge --clear
```

`badge=...` and `--reset=badge` are rejected on purpose, and a plain `--reset`
leaves the badge alone.

## Not using `~/.claude`?

Install elsewhere with `--config-dir`:

```sh
./install.sh --config-dir ~/.claude-work
```

### How the renderer finds its config dir

At runtime the renderer resolves its config dir in this order, first match wins:

| Precedence | Source | Who sets it |
|---|---|---|
| 1 | `--config-dir <path>` (or `--config-dir=<path>`) | You, inside the `statusLine.command` string — see below. |
| 2 | `$STATUSLINE_CONFIG_DIR` | You. The tool-agnostic override. |
| 3 | `$CLAUDE_CONFIG_DIR` | Claude Code, automatically, when it runs against a non-default config dir. |
| 4 | `$HOME/.claude`, then `$USERPROFILE/.claude` | Fallback probe: the first of those holding the file being looked up. Defaults to `$HOME/.claude` if neither does. |

The two env vars are not redundant. **`CLAUDE_CONFIG_DIR` is Claude Code's own**
— you rarely set it by hand; it is already correct when Claude Code runs, which
is why the statusline follows a non-default config dir for free.
**`STATUSLINE_CONFIG_DIR` is this tool's**, and it takes precedence: it is the
one to reach for if you drive the renderer yourself (another prompt, a status
bar, a test harness) with no Claude Code around to set anything, or if you want
the statusline pinned to a dir *regardless* of what Claude Code says.

Both are honoured by the renderer **and** by `statusline-settings.js`, in the
same order, so `/statusline-options` always reads and writes the very file being
rendered. Exporting either one is enough to move both.

> **Two different `--config-dir` flags.** The one in the table is the
> **renderer's**, and you never type it at a prompt — the renderer is exec'd by
> Claude Code, so the flag lives inside the `statusLine.command` string in
> `settings.json`:
> `"command": "bash ~/.claude/statusline-command.sh --config-dir ~/.claude-work"`.
> That pins the renderer to one dir at the top of the precedence list. The
> `--config-dir` in the [Install](#install) section is a different flag on a
> different program: it tells `install.sh` **where to deploy**, once. Setting one
> does not imply the other.

### Configuring a non-default dir

One wrinkle worth knowing: the slash-command files hardcode the **script path**
`node ~/.claude/scripts/claude/statusline-settings.js`. That path is not affected
by `--config-dir`, so if you installed *only* to a different dir, nothing is
deployed at `~/.claude` and `/statusline-options` fails with a module-not-found
error rather than doing the wrong thing quietly.

Which settings file the helper touches is a separate question, and that part is
resolved from the environment — so with the script present, exporting either
config-dir variable points the slash command at the right file:

```sh
export STATUSLINE_CONFIG_DIR=~/.claude-work
```

Or skip the slash command and call the helper by its real path, which needs no
environment at all:

```sh
node ~/.claude-work/scripts/claude/statusline-settings.js options
```

## Tests

```sh
./tests/run.sh      # bats tests/bash + node --test tests/js
```

Requires [bats-core](https://github.com/bats-core/bats-core)
(`sudo apt install -y bats` / `brew install bats-core`) and Node.js.
