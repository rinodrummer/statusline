"use strict";

// Black-box tests for scripts/claude/statusline-settings.js — drives the CLI with
// an isolated CLAUDE_CONFIG_DIR so the real settings file is never touched.

const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");

const SCRIPT = path.resolve(
  __dirname,
  "../../statusline-settings.js"
);
const SCHEMA = path.resolve(__dirname, "../../statusline-settings.schema.json");

// The canonical stored shape, duplicated here on purpose: a test that imported
// the defaults from the script could never catch the script changing them.
const DEFAULT_SECTIONS = {
  context: true,
  five_hour: true,
  seven_day: false,
  advisor: true,
  effort: true,
  caveman: true,
  ponytail: true,
  git: true,
  session_start_date: true,
  agent: true,
};
// nerd_font sits beside style, NOT under sections: it gates no group, it only
// picks which glyphs the git status draws with. Its place in this literal is the
// assertion — every deepStrictEqual below fails if it ever moves under sections.
function defaults(overrides = {}) {
  const { sections, ...rest } = overrides;
  return {
    style: "compact",
    nerd_font: true,
    sections: { ...DEFAULT_SECTIONS, ...sections },
    ...rest,
  };
}

function makeDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "settings-test-"));
}

// Drives the CLI against an isolated config dir.
//
// STATUSLINE_CONFIG_DIR is stripped rather than merely left alone: it outranks
// CLAUDE_CONFIG_DIR in the script's resolution, so a developer with it exported
// would otherwise point every test in this file at their real settings file. Pass
// envOverrides to set it deliberately (the resolution tests below do).
function run(configDir, args, envOverrides = {}) {
  const env = { ...process.env, CLAUDE_CONFIG_DIR: configDir };
  delete env.STATUSLINE_CONFIG_DIR;
  return spawnSync("node", [SCRIPT, ...args], {
    env: { ...env, ...envOverrides },
    encoding: "utf8",
  });
}

function settingsPath(configDir) {
  return path.join(configDir, ".statusline-settings");
}

function readSettings(configDir) {
  return JSON.parse(fs.readFileSync(settingsPath(configDir), "utf8"));
}

function sevenDay(configDir) {
  return readSettings(configDir).sections.seven_day;
}

// Each test owns a temp dir; withDir guarantees cleanup even on failure.
function withDir(fn) {
  const dir = makeDir();
  try {
    fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test("defaults apply when the settings file is absent", () => {
  withDir((dir) => {
    // A no-op-ish read path: toggling weekly from the default off yields on,
    // which proves the absent-file default was off.
    const res = run(dir, ["weekly"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({ sections: { seven_day: true } })
    );
  });
});

test("style verbose and style compact force the value", () => {
  withDir((dir) => {
    let res = run(dir, ["style", "verbose"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).style, "verbose");
    assert.match(res.stdout, /extended ON/);

    res = run(dir, ["style", "compact"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).style, "compact");
    assert.match(res.stdout, /compact/);
  });
});

test("bare style toggles compact <-> verbose", () => {
  withDir((dir) => {
    run(dir, ["style", "compact"]);
    run(dir, ["style"]);
    assert.strictEqual(readSettings(dir).style, "verbose");
    run(dir, ["style"]);
    assert.strictEqual(readSettings(dir).style, "compact");
  });
});

test("weekly on and weekly off force the value", () => {
  withDir((dir) => {
    let res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(sevenDay(dir), true);
    assert.match(res.stdout, /weekly ON/);

    res = run(dir, ["weekly", "off"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(sevenDay(dir), false);
    assert.match(res.stdout, /weekly OFF/);
  });
});

test("bare weekly toggles on <-> off", () => {
  withDir((dir) => {
    run(dir, ["weekly", "off"]);
    run(dir, ["weekly"]);
    assert.strictEqual(sevenDay(dir), true);
    run(dir, ["weekly"]);
    assert.strictEqual(sevenDay(dir), false);
  });
});

test("the legacy weekly command writes sections.seven_day, not a weekly key", () => {
  withDir((dir) => {
    // The shim must land on the canonical key: two stores for one setting is
    // exactly the split brain the consolidation exists to remove.
    run(dir, ["weekly", "on"]);
    assert.ok(!("weekly" in readSettings(dir)));
    assert.strictEqual(sevenDay(dir), true);
  });
});

test("setting one key preserves the other (read-modify-write)", () => {
  withDir((dir) => {
    run(dir, ["style", "verbose"]);
    run(dir, ["weekly", "on"]);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({ style: "verbose", sections: { seven_day: true } })
    );
    // Changing style must not clobber weekly...
    run(dir, ["style", "compact"]);
    assert.strictEqual(sevenDay(dir), true);
    // ...and changing weekly must not clobber style.
    run(dir, ["weekly", "off"]);
    assert.deepStrictEqual(readSettings(dir), defaults());
  });
});

test("malformed JSON falls back to defaults instead of throwing", () => {
  withDir((dir) => {
    fs.writeFileSync(settingsPath(dir), "{ this is not json");
    // No legacy file to migrate from, so the read falls back to defaults:
    // toggling style off the default 'compact' gives 'verbose'.
    const res = run(dir, ["style"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), defaults({ style: "verbose" }));
  });
});

// --- The superseded "weekly" alias --------------------------------------------
//
// Files in the wild hold weekly as the strings "on"/"off" (what this script used
// to write); the schema declares a boolean. Both have to keep working, and both
// have to converge on sections.seven_day as the one stored form.

test("weekly alias is read in both shapes ever written", () => {
  for (const [stored, expected] of [
    ["on", true],
    ["off", false],
    [true, true],
    [false, false],
  ]) {
    withDir((dir) => {
      fs.writeFileSync(settingsPath(dir), JSON.stringify({ weekly: stored }));
      // A style toggle is an unrelated write: it must carry the alias through
      // rather than silently reset the weekly bar the user had turned on.
      const res = run(dir, ["style"]);
      assert.strictEqual(res.status, 0, res.stderr);
      assert.strictEqual(sevenDay(dir), expected, `weekly: ${stored}`);
    });
  }
});

test("weekly alias is dropped from the file on the next write", () => {
  withDir((dir) => {
    fs.writeFileSync(settingsPath(dir), JSON.stringify({ weekly: "on" }));
    run(dir, ["style", "verbose"]);
    assert.ok(!("weekly" in readSettings(dir)), "the alias must not linger");
    assert.strictEqual(sevenDay(dir), true, "but its value must survive");
  });
});

test("canonical sections.seven_day beats the weekly alias when both are present", () => {
  withDir((dir) => {
    // The canonical key is the newer statement by construction — a leftover
    // alias must never override it.
    fs.writeFileSync(
      settingsPath(dir),
      JSON.stringify({ weekly: "on", sections: { seven_day: false } })
    );
    const res = run(dir, ["style"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(sevenDay(dir), false);
  });
});

test("a garbage weekly value falls back to the default, not to true", () => {
  withDir((dir) => {
    fs.writeFileSync(settingsPath(dir), JSON.stringify({ weekly: "yes" }));
    run(dir, ["style"]);
    assert.strictEqual(sevenDay(dir), false);
  });
});

test("a non-object sections key degrades to defaults", () => {
  withDir((dir) => {
    fs.writeFileSync(
      settingsPath(dir),
      JSON.stringify({ style: "verbose", sections: "nonsense" })
    );
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    // The valid sibling key survives; only the garbage one is replaced.
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({ style: "verbose", sections: { seven_day: true } })
    );
  });
});

test("unknown keys in the file are dropped on write", () => {
  withDir((dir) => {
    fs.writeFileSync(
      settingsPath(dir),
      JSON.stringify({ style: "verbose", bogus: 1, sections: { bogus: true } })
    );
    run(dir, ["style"]);
    const settings = readSettings(dir);
    assert.ok(!("bogus" in settings));
    assert.ok(!("bogus" in settings.sections));
  });
});

// --- /statusline-options ------------------------------------------------------

test("options with no arguments prints the config and writes nothing", () => {
  withDir((dir) => {
    const res = run(dir, ["options"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.match(res.stdout, /style: compact/);
    assert.match(res.stdout, /agent: on/);
    assert.match(res.stdout, /seven_day: off/);
    assert.match(res.stdout, /git: on/);
    // A pure read must not materialise a settings file.
    assert.deepStrictEqual(fs.readdirSync(dir), []);
  });
});

test("options --json prints the effective config and writes nothing", () => {
  withDir((dir) => {
    const res = run(dir, ["options", "--json"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(JSON.parse(res.stdout), defaults());
    assert.deepStrictEqual(fs.readdirSync(dir), []);
  });
});

test("options sets several keys in one go", () => {
  withDir((dir) => {
    const res = run(dir, [
      "options",
      "style=verbose",
      "weekly=true",
      "git=false",
      "clock=false",
      "agent=false",
    ]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({
        style: "verbose",
        sections: {
          seven_day: true,
          git: false,
          session_start_date: false,
          agent: false,
        },
      })
    );
  });
});

test("options accepts every boolean vocabulary for sections", () => {
  withDir((dir) => {
    for (const [value, expected] of [
      ["off", false],
      ["on", true],
      ["false", false],
      ["true", true],
      ["0", false],
      ["1", true],
    ]) {
      const res = run(dir, ["options", `git=${value}`]);
      assert.strictEqual(res.status, 0, res.stderr);
      assert.strictEqual(readSettings(dir).sections.git, expected, value);
    }
  });
});

test("boolean values are case-insensitive and stored canonically", () => {
  withDir((dir) => {
    for (const [value, expected] of [
      ["TRUE", true],
      ["False", false],
      ["ON", true],
      ["Off", false],
    ]) {
      const res = run(dir, ["options", `git=${value}`]);
      assert.strictEqual(res.status, 0, res.stderr);
      // A real JSON boolean, not the string the user typed.
      assert.strictEqual(readSettings(dir).sections.git, expected, value);
    }
  });
});

test("style is case-insensitive and stored lowercased", () => {
  withDir((dir) => {
    let res = run(dir, ["options", "style=VERBOSE"]);
    assert.strictEqual(res.status, 0, res.stderr);
    // Canonical on disk: the renderer compares it exactly, so a stored "VERBOSE"
    // would silently read back as compact.
    assert.strictEqual(readSettings(dir).style, "verbose");

    res = run(dir, ["options", "style=CoMpAcT"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).style, "compact");
  });
});

test("the legacy single-key commands fold case too", () => {
  withDir((dir) => {
    // They route through the same validation, so this is a wiring check.
    let res = run(dir, ["style", "VERBOSE"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).style, "verbose");

    res = run(dir, ["weekly", "ON"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(sevenDay(dir), true);
  });
});

// The regression guard that matters: the badge is a raw ANSI string whose case
// is content, not vocabulary. Folding it would corrupt the profile identity the
// user typed — and it is the one value the case-insensitivity must not reach.
test("badge preserves case exactly on its write path", () => {
  const badge = "\x1b[48;5;4m NDU Prod TRUE On \x1b[0m ";
  withDir((dir) => {
    const res = run(dir, ["badge", badge]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).badge, badge);
  });
});

test("badge values that look like booleans are still stored verbatim", () => {
  withDir((dir) => {
    // "TRUE" is a closed-vocabulary word everywhere except here — the badge is
    // content, and case-folding it would corrupt what the user typed.
    const res = run(dir, ["badge", "TRUE"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).badge, "TRUE");
  });
});

test("options maps every section name onto sections.*", () => {
  withDir((dir) => {
    const names = Object.keys(DEFAULT_SECTIONS);
    // Drive each one against its non-default value, so a mis-wired name shows up
    // as an unchanged key rather than passing by coincidence.
    const args = names.map((name) => `${name}=${DEFAULT_SECTIONS[name] ? "false" : "true"}`);
    const res = run(dir, ["options", ...args]);
    assert.strictEqual(res.status, 0, res.stderr);
    for (const name of names) {
      assert.strictEqual(
        readSettings(dir).sections[name],
        !DEFAULT_SECTIONS[name],
        `section ${name}`
      );
    }
  });
});

test("options accepts the sections. prefix, including for the clock alias", () => {
  withDir((dir) => {
    // The issue's own --reset example spells them this way, so the set path has
    // to speak the same dialect.
    let res = run(dir, ["options", "sections.git=false", "sections.clock=false"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).sections.git, false);
    assert.strictEqual(readSettings(dir).sections.session_start_date, false);

    res = run(dir, ["options", "sections.seven_day=true"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(sevenDay(dir), true);
  });
});

test("options rejects the sections. prefix on a key that is not a section", () => {
  withDir((dir) => {
    const res = run(dir, ["options", "sections.style=verbose"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /invalid key/);
  });
});

test("options rejects an unknown key or an invalid value, writing nothing", () => {
  withDir((dir) => {
    run(dir, ["options", "style=verbose"]);
    for (const args of [
      ["options", "bogus=1"],
      ["options", "git=maybe"],
      ["options", "agent=sometimes"],
      ["options", "style=fancy"],
      ["options", "agent_mode=auto"],
    ]) {
      const res = run(dir, args);
      assert.notStrictEqual(res.status, 0, args.join(" "));
      assert.match(res.stderr, /invalid (key|value)/);
    }
    assert.deepStrictEqual(readSettings(dir), defaults({ style: "verbose" }));
  });
});

test("agent is a boolean: the superseded agent=auto is rejected with a pointer", () => {
  withDir((dir) => {
    const res = run(dir, ["options", "agent=auto"]);
    assert.notStrictEqual(res.status, 0);
    // The tri-state never shipped, so there is nothing to migrate — but the
    // spelling is in the issue text, so the error has to say where it went
    // rather than leave someone re-reading the schema.
    assert.match(res.stderr, /agent=true/);
    assert.ok(!fs.existsSync(settingsPath(dir)));
  });
});

test("agent accepts the boolean vocabularies like any other section", () => {
  withDir((dir) => {
    for (const [value, expected] of [
      ["false", false],
      ["true", true],
      ["off", false],
      ["on", true],
      ["0", false],
      ["1", true],
      ["TRUE", true],
      ["Off", false],
    ]) {
      const res = run(dir, ["options", `agent=${value}`]);
      assert.strictEqual(res.status, 0, res.stderr);
      assert.strictEqual(readSettings(dir).sections.agent, expected, value);
    }
  });
});

test("the agent=auto pointer survives a mixed-case spelling", () => {
  withDir((dir) => {
    const res = run(dir, ["options", "agent=AUTO"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /agent=true/);
  });
});

test("options rejects a bare word with no value", () => {
  withDir((dir) => {
    const res = run(dir, ["options", "git"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /<key>=<value>/);
  });
});

test("options validates the whole batch before writing any of it", () => {
  withDir((dir) => {
    run(dir, ["options", "style=compact", "git=true"]);
    // A typo in the last pair must not leave the earlier ones applied — a
    // half-written batch is worse than a rejected one.
    const res = run(dir, ["options", "style=verbose", "git=false", "bogus=1"]);
    assert.notStrictEqual(res.status, 0);
    assert.deepStrictEqual(readSettings(dir), defaults({ style: "compact" }));
  });
});

// The badge is readable through options but not settable there: it is profile
// identity written during profile setup, not a toggle.

test("options rejects badge= and points at the tool that owns it", () => {
  withDir((dir) => {
    run(dir, ["badge", PRINTF_BADGE]);
    const res = run(dir, ["options", "badge=something-else"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /invalid key/);
    // A bare "invalid key" would read like the badge stopped existing.
    assert.match(res.stderr, /create-statusline-badge\.sh/);
    assert.strictEqual(readSettings(dir).badge, PRINTF_BADGE, "left untouched");
  });
});

test("options rejects badge=--clear: it is not the clear path either", () => {
  withDir((dir) => {
    run(dir, ["badge", PRINTF_BADGE]);
    const res = run(dir, ["options", "badge=--clear"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /create-statusline-badge\.sh/);
    assert.strictEqual(readSettings(dir).badge, PRINTF_BADGE);
  });
});

test("options still REPORTS the badge, on both the bare read and --json", () => {
  withDir((dir) => {
    run(dir, ["badge", PRINTF_BADGE]);
    // Not settable is not the same as not visible: dropping it from a config
    // display would be a loss for no gain.
    let res = run(dir, ["options"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.match(res.stdout, /badge: set/);

    res = run(dir, ["options", "--json"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(JSON.parse(res.stdout).badge, PRINTF_BADGE);
  });
});

test("options reports no badge when there is none", () => {
  withDir((dir) => {
    const res = run(dir, ["options"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.match(res.stdout, /badge: \(none\)/);
  });
});

test("an options write carries an existing badge through untouched", () => {
  withDir((dir) => {
    run(dir, ["badge", RAW_ESC_BADGE]);
    const res = run(dir, ["options", "style=verbose", "git=false"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).badge, RAW_ESC_BADGE);
  });
});

test("options does not consume statusline-badge.txt: it owns no badge write", () => {
  withDir((dir) => {
    fs.writeFileSync(settingsPath(dir), JSON.stringify(defaults()));
    const badgeFile = path.join(dir, "statusline-badge.txt");
    fs.writeFileSync(badgeFile, "FROMTXT ");
    const res = run(dir, ["options", "style=verbose"]);
    assert.strictEqual(res.status, 0, res.stderr);
    // The .txt is the renderer's fallback while no badge key exists. options
    // never writes a badge, so it has no business deleting it — that would blank
    // a working badge as a side effect of setting an unrelated option.
    assert.ok(fs.existsSync(badgeFile));
  });
});

// --- /statusline-options --reset ----------------------------------------------

test("--reset restores every option to its default", () => {
  withDir((dir) => {
    run(dir, ["options", "style=verbose", "weekly=true", "git=false", "agent=off"]);
    const res = run(dir, ["options", "--reset"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), defaults());
  });
});

test("--reset keeps the badge: it is profile identity, not an option", () => {
  withDir((dir) => {
    run(dir, ["badge", RAW_ESC_BADGE]);
    run(dir, ["options", "style=verbose"]);
    const res = run(dir, ["options", "--reset"]);
    assert.strictEqual(res.status, 0, res.stderr);
    // Blanking a profile badge from a command that reads as "restore defaults"
    // would be a destructive surprise — and with badge off this surface there is
    // no longer any --reset spelling that touches it.
    assert.strictEqual(readSettings(dir).badge, RAW_ESC_BADGE);
    assert.strictEqual(readSettings(dir).style, "compact");
  });
});

test("--reset=badge is rejected: the badge is not on this surface at all", () => {
  withDir((dir) => {
    run(dir, ["badge", RAW_ESC_BADGE]);
    run(dir, ["options", "style=verbose"]);
    const res = run(dir, ["options", "--reset=badge"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /create-statusline-badge\.sh/);
    assert.strictEqual(readSettings(dir).badge, RAW_ESC_BADGE);
    assert.strictEqual(readSettings(dir).style, "verbose", "nothing was written");
  });
});

test("--reset=<keys> restores only the listed ones", () => {
  withDir((dir) => {
    run(dir, ["options", "style=verbose", "git=false", "clock=false", "weekly=true"]);
    // Spelled the way the issue spells it, prefix and all.
    const res = run(dir, ["options", "--reset=sections.git,sections.clock"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({ style: "verbose", sections: { seven_day: true } })
    );
  });
});

test("--reset=<keys> accepts flat names and tolerates spaces", () => {
  withDir((dir) => {
    run(dir, ["options", "git=false", "weekly=true"]);
    const res = run(dir, ["options", "--reset=git, weekly"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), defaults());
  });
});

test("--reset rejects an unknown key and writes nothing", () => {
  withDir((dir) => {
    run(dir, ["options", "style=verbose"]);
    const res = run(dir, ["options", "--reset=git,bogus"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /invalid key/);
    assert.deepStrictEqual(readSettings(dir), defaults({ style: "verbose" }));
  });
});

test("--reset refuses to be mixed with assignments", () => {
  withDir((dir) => {
    // Ambiguous ordering (reset-then-set or set-then-reset?) — refuse rather
    // than pick one and surprise half the callers.
    const res = run(dir, ["options", "--reset", "style=verbose"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /takes no other arguments/);
  });
});

test("--reset= with no keys is an error", () => {
  withDir((dir) => {
    const res = run(dir, ["options", "--reset="]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /at least one key/);
  });
});

// --- Migration ----------------------------------------------------------------

test("migration: a corrupt settings file re-migrates from the legacy files", () => {
  withDir((dir) => {
    // What an interrupted write used to leave behind. Gated on presence, the
    // next run called it "already migrated" and the legacy values were lost for
    // good; the gate is validity, so this self-heals.
    fs.writeFileSync(settingsPath(dir), '{ "style": "verb');
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    fs.writeFileSync(path.join(dir, "statusline-badge.txt"), PRINTF_BADGE);
    const res = run(dir, ["weekly", "off"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({ style: "verbose", badge: PRINTF_BADGE })
    );
    assert.ok(!fs.existsSync(path.join(dir, ".statusline-style")));
    assert.ok(!fs.existsSync(path.join(dir, "statusline-badge.txt")));
  });
});

test("migration: a valid settings file stays a hard no-op", () => {
  withDir((dir) => {
    // The mirror of the corrupt case: validity gating must not loosen the
    // no-op, or every run would re-consume files the user deleted on purpose.
    fs.writeFileSync(settingsPath(dir), JSON.stringify(defaults()));
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    fs.writeFileSync(path.join(dir, ".statusline-verbose"), "");
    fs.writeFileSync(path.join(dir, "statusline-badge.txt"), PRINTF_BADGE);
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({ sections: { seven_day: true } })
    );
    assert.ok(fs.existsSync(path.join(dir, ".statusline-style")));
    assert.ok(fs.existsSync(path.join(dir, ".statusline-verbose")));
    assert.ok(fs.existsSync(path.join(dir, "statusline-badge.txt")));
  });
});

test("migration: a settings file holding a JSON non-object re-migrates", () => {
  withDir((dir) => {
    // Valid JSON, but not an object: readSettings already treats it as garbage,
    // so the gate must agree rather than call it migrated.
    fs.writeFileSync(settingsPath(dir), "[]");
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    const res = run(dir, ["weekly", "off"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).style, "verbose");
  });
});

test("migration: a legacy weekly-only file is not treated as un-migrated", () => {
  withDir((dir) => {
    // {"weekly":"on"} is a VALID object, so the legacy-file migration must stay
    // a no-op on it — the alias is resolved by the reader, not by re-seeding
    // from files the user may have deleted.
    fs.writeFileSync(settingsPath(dir), JSON.stringify({ weekly: "on" }));
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    const res = run(dir, ["style"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(sevenDay(dir), true);
    assert.strictEqual(readSettings(dir).style, "verbose", "toggled from compact");
    assert.ok(fs.existsSync(path.join(dir, ".statusline-style")));
  });
});

test("write leaves no temp artifact in the config dir", () => {
  withDir((dir) => {
    const res = run(dir, ["style", "verbose"]);
    assert.strictEqual(res.status, 0, res.stderr);
    // The temp file must live beside the target (rename is atomic only within a
    // filesystem) and must not survive the write.
    assert.deepStrictEqual(fs.readdirSync(dir), [".statusline-settings"]);
  });
});

// Skipped on native Windows: NTFS has no POSIX mode bits, so fs.chmodSync can
// only flip the read-only attribute and the mode always reads back as 0o666 or
// 0o444. There is nothing here to preserve and nothing to assert — the invariant
// itself is POSIX-only, not the test. Node reports "win32" even when the suite is
// driven from Git Bash, which is exactly the case this skip is for.
test("write preserves the permissions of an existing settings file", {
  skip: process.platform === "win32" ? "POSIX mode bits do not exist on Windows" : false,
}, () => {
  withDir((dir) => {
    run(dir, ["style", "verbose"]);
    // Rename swaps in a brand-new inode, so its mode has to be carried over —
    // silently retightening a file the user loosened is a surprise.
    fs.chmodSync(settingsPath(dir), 0o640);
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(fs.statSync(settingsPath(dir)).mode & 0o777, 0o640);
  });
});

test("migration: .statusline-style 'verbose' seeds settings and old file is gone", () => {
  withDir((dir) => {
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    // Any run triggers migration before applying the setting; weekly off -> off
    // is a value-preserving way to observe the seeded state.
    const res = run(dir, ["weekly", "off"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), defaults({ style: "verbose" }));
    assert.ok(!fs.existsSync(path.join(dir, ".statusline-style")));
  });
});

test("migration: legacy .statusline-verbose presence seeds verbose", () => {
  withDir((dir) => {
    fs.writeFileSync(path.join(dir, ".statusline-verbose"), "");
    const res = run(dir, ["weekly", "off"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), defaults({ style: "verbose" }));
    assert.ok(!fs.existsSync(path.join(dir, ".statusline-verbose")));
  });
});

test("migration does not run when .statusline-settings already exists", () => {
  withDir((dir) => {
    fs.writeFileSync(
      settingsPath(dir),
      JSON.stringify(defaults({ sections: { seven_day: true } }))
    );
    // A stale predecessor must not be re-consumed nor override the new file.
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({ sections: { seven_day: true } })
    );
    assert.ok(fs.existsSync(path.join(dir, ".statusline-style")));
  });
});

// --- Badge --------------------------------------------------------------------
//
// The badge is a raw ANSI string, in two shapes that both must survive: real ESC
// bytes, and the printf-style literal-backslash form create-statusline-badge.sh
// writes. A mangled badge never errors — it renders as literal escape text.
const RAW_ESC_BADGE = "\x1b[1;35m[work]\x1b[0m ";
const PRINTF_BADGE = "\\x1b[48;5;4m NDU \\x1b[0m ";

test("badge set stores the raw string and clear removes the key", () => {
  withDir((dir) => {
    let res = run(dir, ["badge", PRINTF_BADGE]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).badge, PRINTF_BADGE);

    res = run(dir, ["badge", "--clear"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.ok(!("badge" in readSettings(dir)));
  });
});

test("badge round-trips ANSI escapes byte-for-byte", () => {
  for (const badge of [RAW_ESC_BADGE, PRINTF_BADGE]) {
    withDir((dir) => {
      const res = run(dir, ["badge", badge]);
      assert.strictEqual(res.status, 0, res.stderr);
      // Byte-level identity, not just string equality: what the renderer reads
      // back must be exactly what was handed in.
      assert.deepStrictEqual(
        Buffer.from(readSettings(dir).badge, "utf8"),
        Buffer.from(badge, "utf8")
      );
    });
  }
});

test("badge with an = in it survives: the legacy path takes it verbatim", () => {
  withDir((dir) => {
    // The options path would have had to split on the first '=' to get this
    // right. It no longer accepts badges at all, so the legacy path — the one
    // create-statusline-badge.sh calls — is where this has to hold.
    const badge = "\x1b[44m a=b=c \x1b[0m ";
    const res = run(dir, ["badge", badge]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).badge, badge);
  });
});

test("badge preserves style and weekly, and they preserve the badge", () => {
  withDir((dir) => {
    run(dir, ["style", "verbose"]);
    run(dir, ["weekly", "on"]);
    run(dir, ["badge", RAW_ESC_BADGE]);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({
        style: "verbose",
        badge: RAW_ESC_BADGE,
        sections: { seven_day: true },
      })
    );

    // ...and the other direction: setting the enum keys keeps the badge.
    run(dir, ["style", "compact"]);
    run(dir, ["weekly", "off"]);
    assert.strictEqual(readSettings(dir).badge, RAW_ESC_BADGE);
  });
});

test("badge with no value exits non-zero with usage, no state change", () => {
  withDir((dir) => {
    run(dir, ["badge", PRINTF_BADGE]);
    const res = run(dir, ["badge"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /usage:/);
    assert.strictEqual(readSettings(dir).badge, PRINTF_BADGE);
  });
});

test("migration: statusline-badge.txt folds into the badge key and is removed", () => {
  withDir((dir) => {
    const badgeFile = path.join(dir, "statusline-badge.txt");
    // No trailing newline is added: the badge's trailing space is significant.
    fs.writeFileSync(badgeFile, PRINTF_BADGE);
    const res = run(dir, ["weekly", "off"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), defaults({ badge: PRINTF_BADGE }));
    assert.ok(!fs.existsSync(badgeFile));
  });
});

test("migration: badge folds in alongside a legacy .statusline-style", () => {
  withDir((dir) => {
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    fs.writeFileSync(path.join(dir, "statusline-badge.txt"), PRINTF_BADGE);
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({
        style: "verbose",
        badge: PRINTF_BADGE,
        sections: { seven_day: true },
      })
    );
    assert.ok(!fs.existsSync(path.join(dir, ".statusline-style")));
    assert.ok(!fs.existsSync(path.join(dir, "statusline-badge.txt")));
  });
});

test("migration: badge.txt is not folded in when .statusline-settings exists", () => {
  withDir((dir) => {
    fs.writeFileSync(settingsPath(dir), JSON.stringify(defaults()));
    const badgeFile = path.join(dir, "statusline-badge.txt");
    fs.writeFileSync(badgeFile, PRINTF_BADGE);
    const res = run(dir, ["weekly", "off"]);
    assert.strictEqual(res.status, 0, res.stderr);
    // No badge key: the renderer's own fallback to the .txt covers this case, so
    // migration must not resurrect a file the user may have deleted before.
    assert.ok(!("badge" in readSettings(dir)));
    assert.ok(fs.existsSync(badgeFile));
  });
});

test("badge write consumes a leftover statusline-badge.txt", () => {
  withDir((dir) => {
    fs.writeFileSync(settingsPath(dir), JSON.stringify(defaults()));
    const badgeFile = path.join(dir, "statusline-badge.txt");
    fs.writeFileSync(badgeFile, "stale badge ");
    const res = run(dir, ["badge", PRINTF_BADGE]);
    assert.strictEqual(res.status, 0, res.stderr);
    // Left in place, the stale .txt would resurface through the renderer's
    // fallback the moment the badge key is cleared.
    assert.ok(!fs.existsSync(badgeFile));
  });
});

test("empty badge in the file reads as absent", () => {
  withDir((dir) => {
    fs.writeFileSync(settingsPath(dir), JSON.stringify(defaults({ badge: "" })));
    // An empty badge falls through to the .txt fallback, so it must not be
    // carried over into a rewrite as a live value.
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.ok(!("badge" in readSettings(dir)));
  });
});

// --- Usage errors -------------------------------------------------------------

test("invalid key exits non-zero with usage, no state change", () => {
  withDir((dir) => {
    run(dir, ["style", "compact"]);
    const res = run(dir, ["bogus"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /invalid key/);
    assert.match(res.stderr, /usage:/);
    assert.strictEqual(readSettings(dir).style, "compact");
  });
});

test("invalid value exits non-zero with usage, no state change", () => {
  withDir((dir) => {
    run(dir, ["style", "compact"]);
    let res = run(dir, ["style", "bogus"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /invalid value/);
    assert.strictEqual(readSettings(dir).style, "compact");

    res = run(dir, ["weekly", "maybe"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /invalid value/);
  });
});

test("no arguments exits non-zero with usage", () => {
  withDir((dir) => {
    const res = run(dir, []);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /usage:/);
  });
});

test("built-in --self-check passes", () => {
  const res = spawnSync("node", [SCRIPT, "--self-check"], { encoding: "utf8" });
  assert.strictEqual(res.status, 0, res.stderr);
  assert.match(res.stdout, /self-check OK/);
});

// --- Schema -------------------------------------------------------------------
//
// Nothing validates against the schema at runtime (a settings file that fails
// validation must still render a statusline, not break the prompt), so these are
// the only checks that keep it honest. Builtins only — no ajv.

test("schema declares the same keys and defaults the script implements", () => {
  const schema = JSON.parse(fs.readFileSync(SCHEMA, "utf8"));
  const sections = schema.properties.sections.properties;
  assert.deepStrictEqual(
    Object.keys(sections).sort(),
    Object.keys(DEFAULT_SECTIONS).sort(),
    "schema sections must match the implemented set"
  );
  for (const [name, spec] of Object.entries(sections)) {
    assert.strictEqual(spec.type, "boolean", `${name} must be a boolean`);
    assert.strictEqual(spec.default, DEFAULT_SECTIONS[name], `${name} default`);
  }
  assert.deepStrictEqual(schema.properties.style.enum, ["compact", "verbose"]);
  assert.strictEqual(schema.properties.style.default, "compact");
  // nerd_font is top-level and defaults true. additionalProperties is false, so
  // omitting it from the schema would fail every file the script now writes.
  assert.strictEqual(schema.properties.nerd_font.type, "boolean");
  assert.strictEqual(schema.properties.nerd_font.default, true);
  assert.ok(!("nerd_font" in sections), "nerd_font must not be a section");
  // agent is a section like any other, not a top-level tri-state.
  assert.ok(!("agent_mode" in schema.properties));
  // The badge must stay default-less: a default would make "absent" mean
  // something, and absent is exactly what triggers the .txt fallback.
  assert.ok(!("default" in schema.properties.badge));
  assert.strictEqual(schema.additionalProperties, false);
  assert.strictEqual(schema.properties.sections.additionalProperties, false);
});

// --- nerd_font ---------------------------------------------------------------
//
// A top-level boolean, the first of its kind: style is top-level but an enum, and
// every other boolean lives under sections. These tests pin it to that spot,
// because "which category is it in" is the whole design decision — landing it
// under sections would make it read as a visibility gate, which it is not.

test("nerd_font defaults to true when the file is absent", () => {
  withDir((dir) => {
    const res = run(dir, ["options", "--json"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(JSON.parse(res.stdout).nerd_font, true);
  });
});

test("nerd_font=false is stored top-level, not under sections", () => {
  withDir((dir) => {
    const res = run(dir, ["options", "nerd_font=false"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), defaults({ nerd_font: false }));
    assert.ok(!("nerd_font" in readSettings(dir).sections));
  });
});

test("nerd_font round-trips through options and --json", () => {
  withDir((dir) => {
    run(dir, ["options", "nerd_font=false"]);
    assert.strictEqual(JSON.parse(run(dir, ["options", "--json"]).stdout).nerd_font, false);
    run(dir, ["options", "nerd_font=true"]);
    assert.strictEqual(JSON.parse(run(dir, ["options", "--json"]).stdout).nerd_font, true);
  });
});

test("nerd_font is reported by the human-readable options read", () => {
  withDir((dir) => {
    run(dir, ["options", "nerd_font=false"]);
    assert.match(run(dir, ["options"]).stdout, /nerd_font: off/);
    run(dir, ["options", "nerd_font=true"]);
    assert.match(run(dir, ["options"]).stdout, /nerd_font: on/);
  });
});

test("nerd_font takes the shared boolean vocabulary, case-insensitively", () => {
  withDir((dir) => {
    for (const [spelling, expected] of [
      ["off", false],
      ["ON", true],
      ["0", false],
      ["1", true],
      ["False", false],
    ]) {
      const res = run(dir, ["options", `nerd_font=${spelling}`]);
      assert.strictEqual(res.status, 0, res.stderr);
      assert.strictEqual(readSettings(dir).nerd_font, expected, spelling);
    }
  });
});

test("nerd_font rejects a non-boolean and leaves the file untouched", () => {
  withDir((dir) => {
    run(dir, ["options", "nerd_font=false"]);
    for (const bogus of ["yes", "maybe", "2", "compact", ""]) {
      const res = run(dir, ["options", `nerd_font=${bogus}`]);
      assert.notStrictEqual(res.status, 0, `nerd_font=${bogus} must fail`);
      assert.strictEqual(readSettings(dir).nerd_font, false, "state must survive");
    }
  });
});

test("nerd_font is NOT reachable as sections.nerd_font", () => {
  withDir((dir) => {
    // The prefix is only honoured for names that really live under sections —
    // the same rule that keeps "sections.style" an error.
    const res = run(dir, ["options", "sections.nerd_font=false"]);
    assert.notStrictEqual(res.status, 0);
    assert.match(res.stderr, /invalid key/);
    assert.ok(!fs.existsSync(settingsPath(dir)), "a rejected key must write nothing");
  });
});

test("a settings file holding a non-boolean nerd_font degrades to the default", () => {
  withDir((dir) => {
    // The renderer's exact-match comparison and this reader must agree that only
    // a real JSON boolean counts; the string "false" is not one.
    fs.writeFileSync(settingsPath(dir), JSON.stringify({ nerd_font: "false" }));
    assert.strictEqual(JSON.parse(run(dir, ["options", "--json"]).stdout).nerd_font, true);
  });
});

test("--reset=nerd_font restores true and touches nothing else", () => {
  withDir((dir) => {
    run(dir, ["options", "nerd_font=false", "style=verbose", "git=false"]);
    const res = run(dir, ["options", "--reset=nerd_font"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({ style: "verbose", sections: { git: false } })
    );
  });
});

test("a full reset restores nerd_font to true", () => {
  withDir((dir) => {
    run(dir, ["options", "nerd_font=false"]);
    run(dir, ["options", "--reset"]);
    assert.deepStrictEqual(readSettings(dir), defaults());
  });
});

test("a full reset keeps nerd_font while carrying the badge through", () => {
  withDir((dir) => {
    run(dir, ["badge", PRINTF_BADGE]);
    run(dir, ["options", "nerd_font=false"]);
    run(dir, ["options", "--reset"]);
    assert.deepStrictEqual(readSettings(dir), defaults({ badge: PRINTF_BADGE }));
  });
});

test("nerd_font is listed in the usage key list", () => {
  withDir((dir) => {
    const res = run(dir, ["options", "bogus=1"]);
    assert.match(res.stderr, /option keys:.*nerd_font/);
  });
});

test("setting nerd_font preserves the other keys", () => {
  withDir((dir) => {
    run(dir, ["options", "style=verbose", "weekly=true"]);
    run(dir, ["options", "nerd_font=false"]);
    assert.deepStrictEqual(
      readSettings(dir),
      defaults({ style: "verbose", nerd_font: false, sections: { seven_day: true } })
    );
  });
});

test("schema still declares the superseded weekly alias", () => {
  const schema = JSON.parse(fs.readFileSync(SCHEMA, "utf8"));
  // additionalProperties is false, so dropping this would make every settings
  // file still holding the alias fail validation in an editor.
  assert.strictEqual(schema.properties.weekly.type, "boolean");
  assert.match(schema.properties.weekly.description, /supersed/i);
});

test("a config written by the script validates against the schema's key set", () => {
  withDir((dir) => {
    run(dir, ["options", "style=verbose", "weekly=true"]);
    run(dir, ["badge", PRINTF_BADGE]);
    const schema = JSON.parse(fs.readFileSync(SCHEMA, "utf8"));
    const written = readSettings(dir);
    // additionalProperties: false is only a promise if what we write honours it.
    for (const key of Object.keys(written)) {
      assert.ok(key in schema.properties, `written key ${key} is not in the schema`);
    }
    for (const key of Object.keys(written.sections)) {
      assert.ok(
        key in schema.properties.sections.properties,
        `written section ${key} is not in the schema`
      );
    }
  });
});

// --- config dir resolution ---------------------------------------------------
//
// The precedence is a contract with the renderer's resolve_config_dir, not a
// local choice: both read and write the same .statusline-settings, so if they
// resolve differently, `options` reports settings that are not the ones being
// rendered. These pin the JS side; tests/bash/statusline-command.bats pins the
// renderer's. A change to one without the other should fail here.

test("STATUSLINE_CONFIG_DIR wins over CLAUDE_CONFIG_DIR when reading", () => {
  withDir((claudeDir) => {
    withDir((statuslineDir) => {
      fs.writeFileSync(settingsPath(claudeDir), JSON.stringify({ style: "compact" }));
      fs.writeFileSync(settingsPath(statuslineDir), JSON.stringify({ style: "verbose" }));
      const res = run(claudeDir, ["options", "--json"], {
        STATUSLINE_CONFIG_DIR: statuslineDir,
      });
      assert.strictEqual(res.status, 0);
      assert.strictEqual(JSON.parse(res.stdout).style, "verbose");
    });
  });
});

test("STATUSLINE_CONFIG_DIR wins over CLAUDE_CONFIG_DIR when writing", () => {
  withDir((claudeDir) => {
    withDir((statuslineDir) => {
      const res = run(claudeDir, ["options", "style=verbose"], {
        STATUSLINE_CONFIG_DIR: statuslineDir,
      });
      assert.strictEqual(res.status, 0);
      assert.strictEqual(readSettings(statuslineDir).style, "verbose");
      // the write must not land in the lower-precedence dir at all
      assert.ok(!fs.existsSync(settingsPath(claudeDir)));
    });
  });
});

test("an empty STATUSLINE_CONFIG_DIR reads as unset and falls through", () => {
  // Matches the renderer's `[ -n "${VAR:-}" ]`, which skips an empty value.
  withDir((claudeDir) => {
    fs.writeFileSync(settingsPath(claudeDir), JSON.stringify({ style: "verbose" }));
    const res = run(claudeDir, ["options", "--json"], { STATUSLINE_CONFIG_DIR: "" });
    assert.strictEqual(res.status, 0);
    assert.strictEqual(JSON.parse(res.stdout).style, "verbose");
  });
});

test("CLAUDE_CONFIG_DIR still wins over ~/.claude", () => {
  withDir((claudeDir) => {
    withDir((fakeHome) => {
      fs.mkdirSync(path.join(fakeHome, ".claude"));
      fs.writeFileSync(
        path.join(fakeHome, ".claude", ".statusline-settings"),
        JSON.stringify({ style: "compact" })
      );
      fs.writeFileSync(settingsPath(claudeDir), JSON.stringify({ style: "verbose" }));
      const res = run(claudeDir, ["options", "--json"], {
        HOME: fakeHome,
        USERPROFILE: fakeHome,
      });
      assert.strictEqual(res.status, 0);
      assert.strictEqual(JSON.parse(res.stdout).style, "verbose");
    });
  });
});

test("with neither env var set, the config dir is ~/.claude", () => {
  withDir((fakeHome) => {
    // CLAUDE_CONFIG_DIR="" is the fall-through, leaving the home fallback as the
    // only remaining source — run() always pins CLAUDE_CONFIG_DIR otherwise.
    const res = run(fakeHome, ["options", "style=verbose"], {
      CLAUDE_CONFIG_DIR: "",
      HOME: fakeHome,
      USERPROFILE: fakeHome,
    });
    assert.strictEqual(res.status, 0);
    const written = path.join(fakeHome, ".claude", ".statusline-settings");
    assert.ok(fs.existsSync(written), "settings should be written under ~/.claude");
    assert.strictEqual(JSON.parse(fs.readFileSync(written, "utf8")).style, "verbose");
  });
});

test("--self-check passes and is not hijacked by an ambient STATUSLINE_CONFIG_DIR", () => {
  withDir((dir) => {
    withDir((decoy) => {
      // The check steers itself with CLAUDE_CONFIG_DIR; the higher-precedence var
      // must not redirect its assertions (nor let it write into the decoy).
      const res = run(dir, ["--self-check"], { STATUSLINE_CONFIG_DIR: decoy });
      assert.strictEqual(res.status, 0, res.stderr);
      assert.match(res.stdout, /self-check OK/);
      assert.ok(!fs.existsSync(settingsPath(decoy)));
    });
  });
});
