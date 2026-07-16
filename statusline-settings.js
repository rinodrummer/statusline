#!/usr/bin/env node
"use strict";

/**
 * Set or toggle the statusline settings.
 *
 * Shared contract with the statusline renderer:
 *   Settings file: $CLAUDE_CONFIG_DIR/.statusline-settings
 *                  (default ~/.claude/.statusline-settings)
 *   JSON object: { "style": "compact"|"verbose", "weekly": "on"|"off",
 *                  "badge": "<raw badge string>" }
 *   Absent, unreadable, malformed or missing style/weekly keys -> defaults
 *   (style=compact, weekly=off). Reading never throws. "badge" has no default:
 *   absent or empty means no badge here, and the renderer then falls back to the
 *   superseded "statusline-badge.txt".
 *
 * The badge is a RAW string carrying ANSI escapes ("\x1b[48;5;4m NDU \x1b[0m ").
 * It must round-trip byte-for-byte through JSON — a mangled badge does not
 * error, it renders as literal escape text. JSON.stringify/parse is exact for
 * both the printf-style literal-backslash form written by
 * create-statusline-badge.sh and real ESC bytes, so no escaping is done here.
 *
 * CLI:
 *   statusline-settings.js style [compact|verbose]   set, or toggle if omitted
 *   statusline-settings.js weekly [on|off]           set, or toggle if omitted
 *   statusline-settings.js badge <string>            set the raw badge string
 *   statusline-settings.js badge --clear             drop the badge key
 *   Unknown key or invalid value -> usage on stderr, exit 1, no state change.
 *   badge takes no toggle: an omitted value is an error, not a flip.
 *
 * Migration chain (runs on every invocation, idempotent):
 *   .statusline-verbose -> .statusline-style -> .statusline-settings
 *   statusline-badge.txt                     -> .statusline-settings ("badge")
 *   Older versions used a presence-based ".statusline-verbose" (present =
 *   verbose), then a content-based ".statusline-style", and kept the badge in a
 *   dedicated "statusline-badge.txt". If ".statusline-settings" holds no valid
 *   JSON object (absent, unreadable or corrupt), seed it from whichever legacy
 *   file exists, then remove the superseded files — only after the new file is
 *   written. Once it holds a valid object, migration is a no-op, so a deleted
 *   legacy file is never resurrected. The gate is validity, not presence: a file
 *   left corrupt by an interrupted write must self-heal from the legacy files,
 *   which are still on disk precisely because that write never landed.
 *
 * Cross-platform: Node.js built-ins only. Config dir resolves like the
 * statusline: CLAUDE_CONFIG_DIR if set, else ~/.claude (HOME, or USERPROFILE on
 * Windows-native).
 */

const fs = require("fs");
const path = require("path");
const os = require("os");

const DEFAULTS = { style: "compact", weekly: "off" };
const VALID_VALUES = { style: ["compact", "verbose"], weekly: ["on", "off"] };
// Free-form keys: no default, no enum, absent unless set.
const FREE_FORM_KEYS = ["badge"];
const CLEAR_FLAG = "--clear";
const USAGE =
  "usage: statusline-settings.js <style [compact|verbose] | weekly [on|off] | " +
  `badge <string|${CLEAR_FLAG}>>`;

function configDir() {
  if (process.env.CLAUDE_CONFIG_DIR) {
    return process.env.CLAUDE_CONFIG_DIR;
  }
  const home = os.homedir() || process.env.HOME || process.env.USERPROFILE;
  return path.join(home, ".claude");
}

function settingsPathFor() {
  return path.join(configDir(), ".statusline-settings");
}

function stylePathFor() {
  return path.join(configDir(), ".statusline-style");
}

function legacyFlagPathFor() {
  return path.join(configDir(), ".statusline-verbose");
}

function legacyBadgePathFor() {
  return path.join(configDir(), "statusline-badge.txt");
}

// The settings file's parsed contents, or undefined when it is absent,
// unreadable, or does not hold a JSON object. Never throws.
function parseSettingsFile() {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(settingsPathFor(), "utf8"));
  } catch {
    return undefined;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return undefined;
  }
  return parsed;
}

// Never throws: any read/parse failure falls back to defaults. Unknown keys are
// dropped and invalid values replaced, so a hand-edited file can't wedge things.
function readSettings() {
  const parsed = parseSettingsFile();
  if (parsed === undefined) return { ...DEFAULTS };
  const settings = { ...DEFAULTS };
  for (const key of Object.keys(DEFAULTS)) {
    if (VALID_VALUES[key].includes(parsed[key])) settings[key] = parsed[key];
  }
  // Free-form: kept verbatim (no trim — trailing spaces are part of the badge).
  // An empty string is the same as absent, matching the renderer's fallback rule.
  for (const key of FREE_FORM_KEYS) {
    if (typeof parsed[key] === "string" && parsed[key] !== "") {
      settings[key] = parsed[key];
    }
  }
  return settings;
}

// Atomic: a kill mid-write must never leave a truncated settings file behind —
// the migration that would rebuild it has already consumed the legacy sources.
// The temp file lives in the SAME directory because rename is only atomic within
// one filesystem, and the system temp dir is routinely on another.
function writeSettings(settings) {
  const settingsPath = settingsPathFor();
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  const tempPath = `${settingsPath}.${process.pid}.tmp`;
  // A fresh file gets the umask default, matching what a plain write produced;
  // an existing one keeps its own mode, since rename would otherwise silently
  // retighten a file the user had loosened.
  let mode;
  try {
    mode = fs.statSync(settingsPath).mode;
  } catch {
    // Absent (or unreadable): nothing to preserve, take the umask default.
  }
  try {
    fs.writeFileSync(tempPath, `${JSON.stringify(settings, null, 2)}\n`);
    if (mode !== undefined) fs.chmodSync(tempPath, mode);
    fs.renameSync(tempPath, settingsPath);
  } catch (err) {
    fs.rmSync(tempPath, { force: true });
    throw err;
  }
  return settingsPath;
}

// Read-modify-write: setting one key always preserves the other.
function setKey(key, value) {
  const settings = readSettings();
  settings[key] = value;
  writeSettings(settings);
  return settings;
}

// Read-modify-write, mirroring setKey: dropping the badge preserves style/weekly.
function clearKey(key) {
  const settings = readSettings();
  delete settings[key];
  writeSettings(settings);
  return settings;
}

function toggleKey(key) {
  const [first, second] = VALID_VALUES[key];
  const current = readSettings()[key];
  return setKey(key, current === first ? second : first);
}

// The settings file owns the badge, so the superseded file must go: while it
// lingers, clearing the badge would silently resurrect the stale one through the
// renderer's fallback. Only ever called after the settings write succeeded.
function consumeLegacyBadgeFile() {
  fs.rmSync(legacyBadgePathFor(), { force: true });
}

function applyBadge(value) {
  if (value === undefined || value === "") {
    throw new Error(`badge requires a value or ${CLEAR_FLAG}\n${USAGE}`);
  }
  const settings = value === CLEAR_FLAG ? clearKey("badge") : setKey("badge", value);
  consumeLegacyBadgeFile();
  return settings;
}

// value: undefined/"" -> toggle, valid value -> set. Throws on invalid input.
function applySetting(key, value) {
  if (FREE_FORM_KEYS.includes(key)) return applyBadge(value);
  if (!Object.prototype.hasOwnProperty.call(DEFAULTS, key)) {
    throw new Error(`invalid key: ${key}\n${USAGE}`);
  }
  if (!value) return toggleKey(key);
  if (!VALID_VALUES[key].includes(value)) {
    throw new Error(
      `invalid value for ${key}: ${value} (expected ${VALID_VALUES[key].join(
        " or "
      )})\n${USAGE}`
    );
  }
  return setKey(key, value);
}

// Read the superseded ".statusline-style"/".statusline-verbose" pair, returning
// the style they encode or undefined when neither exists.
function readLegacyStyle() {
  const stylePath = stylePathFor();
  if (fs.existsSync(stylePath)) {
    try {
      const content = fs.readFileSync(stylePath, "utf8").trim();
      if (VALID_VALUES.style.includes(content)) return content;
    } catch {
      // Unreadable: the file existing is still a migration signal, so fall back
      // to the default style rather than skipping the migration entirely.
    }
    return DEFAULTS.style;
  }
  // Legacy semantics: presence means verbose, contents ignored.
  if (fs.existsSync(legacyFlagPathFor())) return "verbose";
  return undefined;
}

// Read the superseded "statusline-badge.txt". Verbatim: the badge's trailing
// space is significant and its escapes must survive byte-for-byte.
function readLegacyBadge() {
  try {
    const content = fs.readFileSync(legacyBadgePathFor(), "utf8");
    return content === "" ? undefined : content;
  } catch {
    return undefined;
  }
}

// Seed ".statusline-settings" from the superseded flag/badge files. No-op once
// the new file holds a valid JSON object, so a removed legacy file is never
// resurrected. Old files are removed only after the new one is written.
//
// Gated on validity rather than presence: a corrupt file counts as not migrated,
// so an interrupted write self-heals from the legacy files instead of skipping
// migration forever and stranding them unread. This is a separate question from
// readSettings, which still degrades a corrupt file to defaults.
function migrateLegacySettings() {
  if (parseSettingsFile() !== undefined) return;

  const style = readLegacyStyle();
  const badge = readLegacyBadge();
  if (style === undefined && badge === undefined) return;

  const settings = { ...DEFAULTS };
  if (style !== undefined) settings.style = style;
  if (badge !== undefined) settings.badge = badge;
  writeSettings(settings);

  // Every predecessor is dead once the new file exists.
  fs.rmSync(stylePathFor(), { force: true });
  fs.rmSync(legacyFlagPathFor(), { force: true });
  consumeLegacyBadgeFile();
}

function formatState(settings, key) {
  if (key === "badge") {
    return settings.badge === undefined
      ? "statusline: badge cleared"
      : "statusline: badge set";
  }
  const styleLabel = settings.style === "verbose" ? "extended ON" : "compact";
  return `statusline: ${styleLabel}, weekly ${settings.weekly.toUpperCase()}`;
}

// ponytail: self-check runs against a temp config dir so it never touches the
// real settings. Invoke with `node statusline-settings.js --self-check`.
function selfCheck() {
  const assert = require("assert");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "statusline-settings-"));
  process.env.CLAUDE_CONFIG_DIR = tmp;
  const read = () => readSettings();
  // defaults apply when the file is absent
  assert.deepStrictEqual(read(), { style: "compact", weekly: "off" });
  // explicit values are forced
  assert.strictEqual(applySetting("style", "verbose").style, "verbose");
  assert.strictEqual(applySetting("weekly", "on").weekly, "on");
  // setting one key preserves the other
  assert.deepStrictEqual(read(), { style: "verbose", weekly: "on" });
  assert.strictEqual(applySetting("style", "compact").weekly, "on");
  // omitted value toggles
  assert.strictEqual(applySetting("style").style, "verbose");
  assert.strictEqual(applySetting("weekly").weekly, "off");
  assert.deepStrictEqual(read(), { style: "verbose", weekly: "off" });
  // invalid input throws and leaves state untouched
  assert.throws(() => applySetting("style", "bogus"));
  assert.throws(() => applySetting("bogus", "on"));
  assert.deepStrictEqual(read(), { style: "verbose", weekly: "off" });
  // malformed JSON falls back to defaults instead of throwing
  fs.writeFileSync(settingsPathFor(), "{not json");
  assert.deepStrictEqual(read(), { style: "compact", weekly: "off" });
  // migration: ".statusline-style" seeds the new file and is consumed
  fs.rmSync(settingsPathFor(), { force: true });
  fs.writeFileSync(stylePathFor(), "verbose\n");
  migrateLegacySettings();
  assert.deepStrictEqual(read(), { style: "verbose", weekly: "off" });
  assert.ok(!fs.existsSync(stylePathFor()));
  // migration: no-op once the new file exists (never re-migrates)
  fs.writeFileSync(stylePathFor(), "compact\n");
  migrateLegacySettings();
  assert.strictEqual(read().style, "verbose");
  assert.ok(fs.existsSync(stylePathFor()));
  // migration: legacy presence-based flag means verbose
  fs.rmSync(settingsPathFor(), { force: true });
  fs.rmSync(stylePathFor(), { force: true });
  fs.writeFileSync(legacyFlagPathFor(), "");
  migrateLegacySettings();
  assert.deepStrictEqual(read(), { style: "verbose", weekly: "off" });
  assert.ok(!fs.existsSync(legacyFlagPathFor()));
  // badge: set/clear preserves the other keys, and no badge key means no badge
  const rawBadge = "\x1b[1;35m[work]\x1b[0m ";
  assert.strictEqual(applySetting("badge", rawBadge).badge, rawBadge);
  // round-trip through the file must be byte-identical: a mangled badge renders
  // as literal escape text instead of erroring.
  assert.strictEqual(read().badge, rawBadge);
  assert.deepStrictEqual(read(), { style: "verbose", weekly: "off", badge: rawBadge });
  assert.strictEqual(applySetting("style", "compact").badge, rawBadge);
  assert.strictEqual(read().badge, rawBadge);
  assert.strictEqual(applySetting("badge", CLEAR_FLAG).badge, undefined);
  assert.deepStrictEqual(read(), { style: "compact", weekly: "off" });
  // badge has no toggle: an omitted value is an error
  assert.throws(() => applySetting("badge"));
  // empty badge in the file reads as absent (renderer falls back to the .txt)
  writeSettings({ ...DEFAULTS, badge: "" });
  assert.strictEqual(read().badge, undefined);
  // migration: "statusline-badge.txt" folds into the badge key and is consumed
  fs.rmSync(settingsPathFor(), { force: true });
  fs.writeFileSync(legacyBadgePathFor(), rawBadge);
  migrateLegacySettings();
  assert.strictEqual(read().badge, rawBadge);
  assert.ok(!fs.existsSync(legacyBadgePathFor()));
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log("statusline-settings: self-check OK");
}

if (require.main === module) {
  if (process.argv[2] === "--self-check") {
    selfCheck();
  } else {
    try {
      migrateLegacySettings();
      const key = process.argv[2];
      console.log(formatState(applySetting(key, process.argv[3]), key));
    } catch (err) {
      process.stderr.write(`statusline-settings: ${err.message}\n`);
      process.exit(1);
    }
  }
}

module.exports = {
  configDir,
  readSettings,
  writeSettings,
  applySetting,
  migrateLegacySettings,
  DEFAULTS,
};
