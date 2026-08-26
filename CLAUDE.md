# CLAUDE.md

A statusline for Claude Code: a bash renderer plus a Node helper that reads and writes its settings. Installs into any Claude Code config dir, defaulting to `~/.claude`.

## Project map

- `statusline-command.sh` — the renderer. Takes session JSON on stdin, prints one line. Requires `jq` and `git`; emits ANSI colours and Nerd Font icons.
- `statusline-settings.js` — reads and writes `.statusline-settings` in the config dir. The only supported writer.
- `statusline-settings.schema.json` — JSON Schema for `.statusline-settings`. Editor autocomplete and test-time validation only; nothing validates at runtime.
- `commands/statusline-{options,style,weekly}.md` — Claude Code slash commands.
- `install.sh` — standalone installer: deploys the pieces into a config dir and wires `statusLine.command` into its `settings.json`.
- `tests/` — `bash/` (bats-core), `js/` (node:test), `run.sh` aggregates both.

Requirements: `jq`, `git`, and a Nerd Font terminal to render; `node` for the helper; `bats-core` for the bash tests.

<important if="you need to run commands to install, test, or inspect the statusline">

| Command | What it does |
|---|---|
| `./install.sh` | Install into `~/.claude`. Copy mode — the default, since a clone is likely to move |
| `./install.sh --mode=symlink` | Link back to this clone instead, so `git pull` updates the installed statusline |
| `./install.sh --config-dir <path>` | Install into a config dir other than `~/.claude` |
| `./install.sh --force` | Replace an existing, unrelated `statusLine` in `settings.json`. Without it, one you already have is left alone and only the wiring is skipped |
| `./tests/run.sh` | Run everything (bats + node:test) |
| `bats tests/bash` | Bash tests only |
| `node --test tests/js/*.test.js` | JS tests only |
| `node statusline-settings.js options` | Print the effective config; `--json` for machine output |
| `node statusline-settings.js options <key>=<value> ...` | Set options. Keys: `advisor`, `agent`, `caveman`, `clock`, `context`, `effort`, `five_hour`, `git`, `nerd_font`, `ponytail`, `session_start_date`, `seven_day`, `style`, `weekly` |
| `node statusline-settings.js options --reset[=<key>,...]` | Restore defaults, all or listed. Keeps the badge |
| `node statusline-settings.js style [compact\|verbose]` | Set, or toggle if omitted |
| `node statusline-settings.js weekly [on\|off]` | Set, or toggle if omitted |
| `node statusline-settings.js badge <string\|--clear>` | The only write path for the badge |
| `node statusline-settings.js --self-check` | Self-test against a temp config dir |
</important>

<important if="you are changing how the config dir is resolved, in either the renderer or the helper">

Precedence: `--config-dir` → `$STATUSLINE_CONFIG_DIR` → `$CLAUDE_CONFIG_DIR` → a dir containing the probe file (`$HOME/.claude`, then `$USERPROFILE/.claude`) → `$HOME/.claude`.

`statusline-command.sh` and `statusline-settings.js` are two independent readers and writers of one settings file, so **both must implement the same precedence or they resolve to different dirs and silently disagree**. Change one, change the other.

The renderer's `resolve_config_dir` takes the probe filename as an argument and is called once per call site on purpose — the sites probe different files and can legitimately land in different dirs. Do not collapse them into a single resolved dir.
</important>

<important if="you are writing or modifying bash in this repo">

Every script is `#!/bin/bash`, and macOS ships bash 3.2 — so bash 4+ syntax breaks for anyone on a Mac: no `${var,,}` / `${var^^}`, no `declare -A`, no `mapfile` / `readarray`. `install.sh` folds case by hand for exactly this reason; match that.

`sed -i` also differs between GNU and BSD. Prefer a temp file and a copy over in-place editing.
</important>

<important if="you are touching the `statusLine.command` string install.sh writes, or anything that assumes POSIX paths at runtime">

There are **two host platforms, not one**, and they differ in who runs the command:

- POSIX (Linux, macOS, **WSL**): Claude Code and the shell agree. `bash <posix-path>`, `printf %q`-quoted. Unchanged.
- **Git Bash / MSYS2 / Cygwin** (`uname -s` = `MINGW*`/`MSYS*`/`CYGWIN*`): Claude Code is the *native Windows* build and hands the string to **cmd.exe**. `install.sh` writes `"<win-path-to-bash.exe>" "<win-path-to-renderer>"` — both via `cygpath -m`, both in cmd's quoting, not POSIX's (`printf %q` emits backslash escapes cmd passes through literally).

Why the bare word `bash` is not merely wrong there but **silently** wrong: Git for Windows puts only its `cmd` dir on `PATH` (git.exe, no shell), while `C:\Windows\System32\bash.exe` — the WSL launcher — is on `PATH` by default on Windows 10/11 regardless of whether a distro exists. So `bash <path>` resolves, runs, prints an error on stderr and nothing on stdout. The install reports success and the statusline is blank. Any future change here must keep the two spellings distinct.

`windows_bash_path` probes its two bash.exe candidates **twice, in two spellings**, and both passes are load-bearing:

- `win_to_posix` (the drive-letter form, `/c/...`) is deliberately not `cygpath -u`: the MSYS mount table aliases `/bin` onto `/usr/bin`, so `cygpath -u` collapses the two candidates and the `-f` probe inspects the wrong file. Only the drive-letter form can tell them apart — which matters because plain MSYS2 has no top-level `bin` at all.
- `cygpath -u` is then the fallback, and it is the pass that finds anything **on Cygwin**, where drives are mounted at `/cygdrive/c` and the drive-letter form matches nothing. Safe as a second pass only: on MSYS the first pass has already returned, and Cygwin has no separate `usr/bin` on disk so its first candidate is the right answer.

`<root>/bin/bash.exe` is preferred over `<root>/usr/bin/bash.exe` because on Git for Windows it is the launcher, which sets `MSYSTEM=MINGW64` and so puts `/mingw64/bin` (git) on `PATH`.

**Where Claude Code runs and where the renderer runs are two different questions.** A native-Windows Claude Code can shell into WSL to render (`statusLine.command` = `wsl bash -c '~/.claude/statusline-command.sh'`), and then the renderer is on Linux while `cwd` and `transcript_path` arrive as Windows paths. `windows_path_to_local` handles it, and the `[ -e ]` guard is the whole design: a drive-letter path that **already resolves** is passed through untouched, which is what keeps MSYS/Cygwin — where `D:\git\x` is valid — out of the translation branch entirely. Only an unresolvable one goes to `wslpath` (preferred over hand-building `/mnt/<drive>/`, since `automount.root` is configurable). Untranslated under WSL, `git -C` fails and the **entire line-2 git group disappears while `sections.git` still reads as on** — the failure mode that makes this look like a settings bug rather than a path bug.

The renderer itself needs no platform branch, but two more Windows facts constrain it:

- **`jq.exe` writes CRLF.** It opens stdout in text mode, so every line it emits ends `\r\n`. `$(...)` hides this — MSYS bash strips one trailing CR off a command substitution — but **`read` does not**, so the `.statusline-settings` positional block (the only `read` in the renderer) must strip CR before parsing. Getting this wrong is silent and total: an *absent* section key arrives as `"\r"`, which is non-empty, so `section_enabled` never reaches its default and reads it as false. Every section switches off the moment a settings file exists. Any new `read` of jq output needs the same guard. Covered by the `crlf_jq_shim` tests.
- **MSYS accepts backslash paths, jq does not.** `basename`, `test -f` and `git -C` all handle `D:\git\x`, so the renderer needs no conversion — but anything splitting a path *inside a jq filter* must fold `\` to `/` first (see `added_dirs`). Claude Code on Windows sends `cwd`, `transcript_path` and `added_dirs` in Windows form.

`tests/bash/install.bats` covers this; its Windows cases `skip` unless the suite is itself running under MSYS/Cygwin, so a green run on Linux proves nothing about that branch.
</important>

<important if="you are touching the badge, or the `badge` subcommand's name or arguments">

Badge precedence in the renderer: the `badge` key in `.statusline-settings` wins whenever it is present and non-empty; empty or absent falls back to the superseded `statusline-badge.txt`. So anything writing a badge must write the **key** — writing only the `.txt` while a `badge` key exists leaves the new badge silently ignored, because the fallback is never reached.

`badge` is deliberately read-only through `options`: it is reported, but `badge=...` and `--reset=badge` are rejected. It is identity, not a toggle.

The `badge <string|--clear>` subcommand is a **cross-repo interface**. [rinodrummer/dotfiles](https://github.com/rinodrummer/dotfiles) calls it from `create-statusline-badge.sh`, and nothing in this repo's test suite would notice a rename — the breakage surfaces over there, silently. Renaming it is a breaking change to a consumer you cannot see from here.
</important>

<important if="you are adding a settings key, or touching nerd_font and the git glyphs">

Keys fall in three categories, and the category decides where the key lives:

- `SECTION_DEFAULTS` -> stored as `sections.<name>`. A section **gates one renderable group**: false omits it entirely. If the key hides nothing, it is not a section.
- `TOGGLE_DEFAULTS` -> a top-level boolean (`nerd_font`). Presentation, not visibility.
- `SCALAR_DEFAULTS` + `VALID_VALUES` -> a top-level enum (`style`).

`nerd_font` is the worked example: it changes which glyphs the git group draws with and omits nothing, so it is top-level. Filing it under `sections` would make `git=false` and `nerd_font=false` read as the same kind of switch when one deletes the group and the other redraws it. Set/toggle branch on `isBooleanPath` (type), not `isSectionPath` (position).

`schema.json` is `additionalProperties: false`: a new key MUST be declared there, or every file the script writes fails validation. `tests/js` duplicates the canonical shape in its own `defaults()` literal on purpose — a test importing the script's defaults could never catch them changing.

**The renderer's fallback criterion is "no Private Use Area glyph" (U+E000-U+F8FF), NOT "ASCII".** PUA is what draws as tofu without a Nerd Font. Ordinary Unicode — `✓` U+2713 (Dingbats), `↑` U+2191 (Arrows), the `█▓▒░` bar shades (Block Elements), `↻` U+21BB — renders in any normal font and must NOT be degraded to an ASCII approximation. Before adding a glyph, check its block; before adding a fallback, check the glyph actually needs one.

**"Not PUA" is necessary but not sufficient.** A fallback glyph must also live in a **well-covered block** and be **single-width**. The worked example: for `staged` we looked for a character combining `^` and `+`. One exists — `⨣` U+2A23 PLUS SIGN WITH CIRCUMFLEX ACCENT ABOVE — and it is not PUA, but it lives in Supplemental Mathematical Operators (U+2A00-U+2AFF), a block ordinary fonts cover poorly, so it would draw as tofu for exactly the limited-font users the fallback exists to serve. `➕` U+2795 fails the other half: Dingbats coverage is decent, but it is emoji-presentation and often double-width, which breaks the column alignment. Both rejected; `^` (plain ASCII) shipped. A fallback that reintroduces tofu or misaligns the line has defeated the option it was written for.

The three-symbol run is ordered as the lifecycle it describes: `+` new, `^` staged (rising), `↑` gone up. That is why `ahead` took `↑` and freed `^` for `staged`.

Known PUA still unswitched by `nerd_font`, both outside the git group: the context warning triangle (U+F071) and `clock_icon` (U+F017). Deliberate — the option is documented as covering the git icons. Widening it means renaming the concept too.

Renderer plumbing: settings are parsed by ONE `jq -r` emitting a positional list, then re-read by a matching run of `IFS= read -r`. **Add to both, at the same index, or every value below silently shifts by one.** Absent/empty/non-boolean must degrade to the default, and comparisons are exact (`= "false"`) because the helper normalises on write.
</important>

<important if="you are changing where install.sh deploys files">

The destinations are a contract, not an implementation detail: `<config-dir>/statusline-command.sh` and `<config-dir>/scripts/claude/statusline-settings.js`. The slash commands in `commands/` hardcode the second one, and downstream consumers hardcode both — `settings.json`, shell aliases, and dotfiles' profile tooling and git hooks. Repoint sources freely; moving a destination breaks consumers that never appear in this repo's tests.
</important>

<important if="you are writing or modifying tests">

`node --test` needs the glob (`tests/js/*.test.js`), not the bare directory — pointing it at `tests/js` fails to resolve the module under test.

Fixture repos should pin `core.autocrlf false`: a contributor with `autocrlf=true` globally otherwise makes any line-ending assertion non-deterministic.

**`@test` names must be ASCII.** bats encodes each name into a shell function name, and under MSYS/Git Bash the multibyte round-trip breaks: bats reports `unknown test name` and the test never runs — dropped from the count rather than failed, so the suite looks green while three tests did nothing. Spell a glyph under test as its codepoint in the title (`U+2191`, `U+2713`), never as the character.
</important>
