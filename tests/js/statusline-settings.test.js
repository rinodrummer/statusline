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
  "../../scripts/claude/statusline-settings.js"
);

function makeDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "settings-test-"));
}

function run(configDir, args) {
  return spawnSync("node", [SCRIPT, ...args], {
    env: { ...process.env, CLAUDE_CONFIG_DIR: configDir },
    encoding: "utf8",
  });
}

function settingsPath(configDir) {
  return path.join(configDir, ".statusline-settings");
}

function readSettings(configDir) {
  return JSON.parse(fs.readFileSync(settingsPath(configDir), "utf8"));
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
    // A no-op-ish read path: toggling weekly from the default 'off' yields 'on',
    // which proves the absent-file default was 'off'.
    const res = run(dir, ["weekly"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), { style: "compact", weekly: "on" });
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
    assert.strictEqual(readSettings(dir).weekly, "on");
    assert.match(res.stdout, /weekly ON/);

    res = run(dir, ["weekly", "off"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.strictEqual(readSettings(dir).weekly, "off");
    assert.match(res.stdout, /weekly OFF/);
  });
});

test("bare weekly toggles on <-> off", () => {
  withDir((dir) => {
    run(dir, ["weekly", "off"]);
    run(dir, ["weekly"]);
    assert.strictEqual(readSettings(dir).weekly, "on");
    run(dir, ["weekly"]);
    assert.strictEqual(readSettings(dir).weekly, "off");
  });
});

test("setting one key preserves the other (read-modify-write)", () => {
  withDir((dir) => {
    run(dir, ["style", "verbose"]);
    run(dir, ["weekly", "on"]);
    assert.deepStrictEqual(readSettings(dir), {
      style: "verbose",
      weekly: "on",
    });
    // Changing style must not clobber weekly...
    run(dir, ["style", "compact"]);
    assert.deepStrictEqual(readSettings(dir), {
      style: "compact",
      weekly: "on",
    });
    // ...and changing weekly must not clobber style.
    run(dir, ["weekly", "off"]);
    assert.deepStrictEqual(readSettings(dir), {
      style: "compact",
      weekly: "off",
    });
  });
});

test("malformed JSON falls back to defaults instead of throwing", () => {
  withDir((dir) => {
    fs.writeFileSync(settingsPath(dir), "{ this is not json");
    // No legacy file to migrate from, so the read falls back to defaults:
    // toggling style off the default 'compact' gives 'verbose'.
    const res = run(dir, ["style"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), {
      style: "verbose",
      weekly: "off",
    });
  });
});

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
    assert.deepStrictEqual(readSettings(dir), {
      style: "verbose",
      weekly: "off",
      badge: PRINTF_BADGE,
    });
    assert.ok(!fs.existsSync(path.join(dir, ".statusline-style")));
    assert.ok(!fs.existsSync(path.join(dir, "statusline-badge.txt")));
  });
});

test("migration: a valid settings file stays a hard no-op", () => {
  withDir((dir) => {
    // The mirror of the corrupt case: validity gating must not loosen the
    // no-op, or every run would re-consume files the user deleted on purpose.
    fs.writeFileSync(
      settingsPath(dir),
      JSON.stringify({ style: "compact", weekly: "off" })
    );
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    fs.writeFileSync(path.join(dir, ".statusline-verbose"), "");
    fs.writeFileSync(path.join(dir, "statusline-badge.txt"), PRINTF_BADGE);
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), {
      style: "compact",
      weekly: "on",
    });
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

test("write leaves no temp artifact in the config dir", () => {
  withDir((dir) => {
    const res = run(dir, ["style", "verbose"]);
    assert.strictEqual(res.status, 0, res.stderr);
    // The temp file must live beside the target (rename is atomic only within a
    // filesystem) and must not survive the write.
    assert.deepStrictEqual(fs.readdirSync(dir), [".statusline-settings"]);
  });
});

test("write preserves the permissions of an existing settings file", () => {
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
    assert.deepStrictEqual(readSettings(dir), {
      style: "verbose",
      weekly: "off",
    });
    assert.ok(!fs.existsSync(path.join(dir, ".statusline-style")));
  });
});

test("migration: legacy .statusline-verbose presence seeds verbose", () => {
  withDir((dir) => {
    fs.writeFileSync(path.join(dir, ".statusline-verbose"), "");
    const res = run(dir, ["weekly", "off"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), {
      style: "verbose",
      weekly: "off",
    });
    assert.ok(!fs.existsSync(path.join(dir, ".statusline-verbose")));
  });
});

test("migration does not run when .statusline-settings already exists", () => {
  withDir((dir) => {
    fs.writeFileSync(
      settingsPath(dir),
      JSON.stringify({ style: "compact", weekly: "on" })
    );
    // A stale predecessor must not be re-consumed nor override the new file.
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), {
      style: "compact",
      weekly: "on",
    });
    assert.ok(fs.existsSync(path.join(dir, ".statusline-style")));
  });
});

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

test("badge preserves style and weekly, and they preserve the badge", () => {
  withDir((dir) => {
    run(dir, ["style", "verbose"]);
    run(dir, ["weekly", "on"]);
    run(dir, ["badge", RAW_ESC_BADGE]);
    assert.deepStrictEqual(readSettings(dir), {
      style: "verbose",
      weekly: "on",
      badge: RAW_ESC_BADGE,
    });

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
    assert.deepStrictEqual(readSettings(dir), {
      style: "compact",
      weekly: "off",
      badge: PRINTF_BADGE,
    });
    assert.ok(!fs.existsSync(badgeFile));
  });
});

test("migration: badge folds in alongside a legacy .statusline-style", () => {
  withDir((dir) => {
    fs.writeFileSync(path.join(dir, ".statusline-style"), "verbose\n");
    fs.writeFileSync(path.join(dir, "statusline-badge.txt"), PRINTF_BADGE);
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.deepStrictEqual(readSettings(dir), {
      style: "verbose",
      weekly: "on",
      badge: PRINTF_BADGE,
    });
    assert.ok(!fs.existsSync(path.join(dir, ".statusline-style")));
    assert.ok(!fs.existsSync(path.join(dir, "statusline-badge.txt")));
  });
});

test("migration: badge.txt is not folded in when .statusline-settings exists", () => {
  withDir((dir) => {
    fs.writeFileSync(
      settingsPath(dir),
      JSON.stringify({ style: "compact", weekly: "off" })
    );
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
    fs.writeFileSync(settingsPath(dir), JSON.stringify({ style: "compact", weekly: "off" }));
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
    fs.writeFileSync(
      settingsPath(dir),
      JSON.stringify({ style: "compact", weekly: "off", badge: "" })
    );
    // An empty badge falls through to the .txt fallback, so it must not be
    // carried over into a rewrite as a live value.
    const res = run(dir, ["weekly", "on"]);
    assert.strictEqual(res.status, 0, res.stderr);
    assert.ok(!("badge" in readSettings(dir)));
  });
});

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
