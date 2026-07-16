#!/usr/bin/env node
"use strict";

/**
 * Read, set, toggle and reset the statusline settings.
 *
 * Shared contract with the statusline renderer:
 *   Settings file: $STATUSLINE_CONFIG_DIR or $CLAUDE_CONFIG_DIR, else
 *                  ~/.claude/.statusline-settings
 *   JSON object, canonical shape:
 *     {
 *       "style": "compact"|"verbose",       // default "compact"
 *       "badge": "<raw badge string>",      // no default
 *       "sections": {                       // every key a boolean
 *         "context": true, "five_hour": true, "seven_day": false,
 *         "advisor": true, "effort": true, "caveman": true,
 *         "ponytail": true, "git": true, "session_start_date": true,
 *         "agent": true
 *       }
 *     }
 *   Absent, unreadable, malformed or missing keys -> defaults. Reading never
 *   throws. "badge" has no default: absent or empty means no badge here, and the
 *   renderer then falls back to the superseded "statusline-badge.txt".
 *   Authoritative declaration: statusline-settings.schema.json in the repo root
 *   (editor autocomplete + test-time checks only — nothing validates at runtime).
 *
 * "weekly" is a COMPATIBILITY ALIAS for sections.seven_day, not a stored key.
 * Files in the wild hold it as the strings "on"/"off" (the shape this script
 * used to write); the issue's schema declares a boolean. Both are accepted on
 * read, sections.seven_day is the single canonical stored form, and the alias is
 * dropped from the file on the next write. sections.seven_day wins when both are
 * present — the canonical key is never overridden by the alias it replaced.
 *
 * The badge is a RAW string carrying ANSI escapes ("\x1b[48;5;4m NDU \x1b[0m ").
 * It must round-trip byte-for-byte through JSON — a mangled badge does not
 * error, it renders as literal escape text. JSON.stringify/parse is exact for
 * both the printf-style literal-backslash form written by
 * create-statusline-badge.sh and real ESC bytes, so no escaping is done here.
 *
 * CLI:
 *   Legacy single-key form (what the statusline-style shell alias fronts):
 *     statusline-settings.js style [compact|verbose]   set, or toggle if omitted
 *     statusline-settings.js weekly [on|off]           set, or toggle if omitted
 *     statusline-settings.js badge <string>            set the raw badge string
 *     statusline-settings.js badge --clear             drop the badge key
 *   Canonical multi-key form (what /statusline-options fronts):
 *     statusline-settings.js options                          print the config
 *     statusline-settings.js options --json                   print it as JSON
 *     statusline-settings.js options style=verbose git=false  set any number
 *     statusline-settings.js options --reset                  all keys to default
 *     statusline-settings.js options --reset=sections.git,clock  selected keys
 *   Unknown key or invalid value -> usage on stderr, exit 1, no state change.
 *   badge takes no toggle: an omitted value is an error, not a flip.
 *
 * The badge is READ-ONLY through `options`: it is reported by the bare read and
 * by --json, but `badge=...` and --reset=badge are rejected. It is profile
 * identity written by create-statusline-badge.sh during setup, not a toggle, so
 * the only write path is the legacy `badge <string|--clear>` subcommand above —
 * which is exactly what create-statusline-badge.sh calls. The asymmetry is the
 * point: showing it costs nothing and helps; letting `options` overwrite it does
 * not.
 *
 * Value spellings (CLI only — the stored file always holds the canonical form):
 *   Booleans take true|on|1 / false|off|0, and the style enum takes its own two
 *   words, all case-insensitively: they are closed vocabularies, so folding can
 *   only turn a typo into the value the user meant. Both are normalised before
 *   they are written, so the renderer never has to be tolerant of a spelling.
 *   The BADGE is exempt and taken byte-for-byte: it is a raw user string, and
 *   case-folding it would corrupt the very content it exists to carry.
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
 *   The "weekly" alias fold-in is deliberately NOT part of this chain: it lives
 *   in readSettings, because a valid file holding "weekly" is not un-migrated —
 *   it just needs the alias resolved on every read, whether or not it is rewritten.
 *
 * Cross-platform: Node.js built-ins only. Config dir resolves like the
 * statusline: STATUSLINE_CONFIG_DIR, then CLAUDE_CONFIG_DIR, then ~/.claude
 * (HOME, or USERPROFILE on Windows-native). See configDir below — that order is
 * a contract with the renderer, not a local preference.
 */

const fs = require("fs");
const path = require("path");
const os = require("os");

// Enum-valued top-level keys.
const SCALAR_DEFAULTS = { style: "compact" };
const VALID_VALUES = {
  style: ["compact", "verbose"],
};
// Every togglable renderer section, with the default the renderer must agree on.
// seven_day is the one opt-in section: a weekly bar most sessions do not want.
const SECTION_DEFAULTS = {
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
// Free-form keys: no default, no enum, absent unless set.
const FREE_FORM_KEYS = ["badge"];
const CLEAR_FLAG = "--clear";
const RESET_FLAG = "--reset";
const JSON_FLAG = "--json";
const LEGACY_KEYS = ["style", "weekly", "badge"];

// The full default config, freshly built each call so callers can mutate it.
function defaults() {
  return { ...SCALAR_DEFAULTS, sections: { ...SECTION_DEFAULTS } };
}

// User-facing option names -> canonical dotted paths. The command UX is flatter
// than the stored schema on purpose ("git", not "sections.git"), and carries two
// aliases the schema has no key for: "weekly" (the superseded storage key) and
// "clock" (the line-2 start-time + duration group, stored as
// sections.session_start_date).
// The badge is deliberately absent: it is READABLE through `options` but not
// settable there. It is profile identity written by create-statusline-badge.sh
// during profile setup, not a toggle the user reaches for — and keeping it off
// this surface is what stops a stray `badge=` from overwriting it. The legacy
// `badge <string|--clear>` subcommand is its one write path.
const OPTION_PATHS = {
  style: "style",
  weekly: "sections.seven_day",
  clock: "sections.session_start_date",
};
for (const section of Object.keys(SECTION_DEFAULTS)) {
  OPTION_PATHS[section] = `sections.${section}`;
}

const USAGE = [
  "usage:",
  "  statusline-settings.js style [compact|verbose]   set, or toggle if omitted",
  "  statusline-settings.js weekly [on|off]           set, or toggle if omitted",
  `  statusline-settings.js badge <string|${CLEAR_FLAG}>`,
  `  statusline-settings.js options [${JSON_FLAG}]`,
  "  statusline-settings.js options <key>=<value> ...",
  `  statusline-settings.js options ${RESET_FLAG}[=<key>,<key>...]`,
  `  option keys: ${Object.keys(OPTION_PATHS).sort().join(", ")}`,
  "  booleans: true|on|1 / false|off|0, case-insensitive.",
  "  the badge is shown by `options` but only written by `badge` above,",
  "  which takes its value verbatim.",
].join("\n");

// Resolves the config dir holding .statusline-settings.
//
// The precedence mirrors the renderer's resolve_config_dir: $STATUSLINE_CONFIG_DIR
// (this tool's own override), then $CLAUDE_CONFIG_DIR (which Claude Code sets
// itself), then ~/.claude. That agreement is the point, not a nicety: the renderer
// and this helper are two independent readers/writers of ONE .statusline-settings,
// so a dir resolved differently here makes `options` report settings that are not
// the ones being rendered — the exact failure the schema contract exists to
// prevent. A change to the order on either side must land on both.
//
// Truthiness rather than an `in process.env` check, deliberately: the renderer's
// `[ -n "${VAR:-}" ]` treats VAR="" as unset and falls through to the next source,
// and "" is falsy here, so both skip an empty value identically. Tightening this
// into an explicit undefined check would silently split the two apart again.
//
// The renderer's fourth step — probing $HOME/.claude then $USERPROFILE/.claude for
// the file — is intentionally NOT mirrored. It exists so a *reader* can find an
// existing file on either side of a WSL/Windows split; this helper writes, and a
// writer cannot probe for a file that does not exist yet. It resolves the one dir
// it would create the file in instead.
function configDir() {
  if (process.env.STATUSLINE_CONFIG_DIR) {
    return process.env.STATUSLINE_CONFIG_DIR;
  }
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

// The superseded "weekly" key, as a boolean, or undefined when it is absent or
// holds something neither shape ever wrote. Both the historical "on"/"off"
// strings and the schema's boolean are accepted — files written by either
// generation of this script have to keep working untouched.
function weeklyAlias(parsed) {
  const value = parsed.weekly;
  if (typeof value === "boolean") return value;
  if (value === "on") return true;
  if (value === "off") return false;
  return undefined;
}

// Never throws: any read/parse failure falls back to defaults. Unknown keys are
// dropped and invalid values replaced, so a hand-edited file can't wedge things.
// Returns the EFFECTIVE config — every key present, defaults filled in — which
// is also exactly what gets written back, so a write canonicalises the file.
function readSettings() {
  const parsed = parseSettingsFile();
  const settings = defaults();
  if (parsed === undefined) return settings;

  for (const key of Object.keys(SCALAR_DEFAULTS)) {
    if (VALID_VALUES[key].includes(parsed[key])) settings[key] = parsed[key];
  }

  const sections =
    parsed.sections && typeof parsed.sections === "object" && !Array.isArray(parsed.sections)
      ? parsed.sections
      : {};
  for (const key of Object.keys(SECTION_DEFAULTS)) {
    if (typeof sections[key] === "boolean") settings.sections[key] = sections[key];
  }
  // The alias only speaks when the canonical key stayed silent: an explicit
  // sections.seven_day is a deliberate newer statement than a leftover "weekly".
  if (typeof sections.seven_day !== "boolean") {
    const alias = weeklyAlias(parsed);
    if (alias !== undefined) settings.sections.seven_day = alias;
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

// Resolve a user-facing option name to its canonical dotted path. Accepts the
// flat name ("git") and the schema-qualified one ("sections.git"), including for
// the two aliases the schema has no key for ("sections.clock" resolves, since the
// issue's own --reset example spells it that way). Returns undefined if unknown.
function resolvePath(name) {
  if (Object.prototype.hasOwnProperty.call(OPTION_PATHS, name)) {
    return OPTION_PATHS[name];
  }
  if (name.startsWith("sections.")) {
    const bare = name.slice("sections.".length);
    const resolved = OPTION_PATHS[bare];
    // Only a name that really lives under sections may wear the prefix —
    // "sections.style" must stay an error rather than silently mean "style".
    if (resolved && resolved.startsWith("sections.")) return resolved;
  }
  return undefined;
}

// resolvePath, but throwing the error the CLI should show. Shared by the set and
// the --reset paths so "badge" gets pointed at its real tool from both, rather
// than a bare "invalid key" that reads like the badge stopped existing.
function resolvePathOrThrow(name) {
  const dottedPath = resolvePath(name);
  if (dottedPath !== undefined) return dottedPath;
  const hint =
    name.toLowerCase() === "badge" || name.toLowerCase() === "sections.badge"
      ? "\nthe badge is not settable here — it is profile identity, written by" +
        "\ncreate-statusline-badge.sh during profile setup. `options` shows it," +
        "\nand `statusline-settings.js badge <string|--clear>` is its write path."
      : "";
  throw new Error(`invalid key: ${name}${hint}\n${USAGE}`);
}

function getAtPath(settings, dottedPath) {
  const [head, tail] = dottedPath.split(".");
  return tail === undefined ? settings[head] : settings[head][tail];
}

function setAtPath(settings, dottedPath, value) {
  const [head, tail] = dottedPath.split(".");
  if (tail === undefined) settings[head] = value;
  else settings[head][tail] = value;
}

function deleteAtPath(settings, dottedPath) {
  const [head, tail] = dottedPath.split(".");
  if (tail === undefined) delete settings[head];
  else delete settings[head][tail];
}

// Booleans arrive in three vocabularies: "true"/"false" (the schema, and what
// /statusline-options documents), "on"/"off" (what the superseded weekly command
// took, and what muscle memory types) and "1"/"0". All are accepted everywhere,
// case-insensitively — this is a closed vocabulary, so folding it can only ever
// turn a typo into the value the user meant.
//
// Only ever fed CLI input. The settings FILE is not parsed through here: it
// holds real JSON booleans, and readSettings type-checks them directly.
function parseBoolean(value) {
  const normalised = value.toLowerCase();
  if (normalised === "true" || normalised === "on" || normalised === "1") return true;
  if (normalised === "false" || normalised === "off" || normalised === "0") return false;
  return undefined;
}

function isSectionPath(dottedPath) {
  return dottedPath.startsWith("sections.");
}

// Apply one name=value pair onto an in-memory settings object. Throws on an
// unknown name or an invalid value, before anything is written.
function applyAssignment(settings, name, rawValue) {
  const dottedPath = resolvePathOrThrow(name);
  if (rawValue === undefined || rawValue === "") {
    throw new Error(`${name} requires a value\n${USAGE}`);
  }
  if (isSectionPath(dottedPath)) {
    const parsed = parseBoolean(rawValue);
    if (parsed === undefined) {
      // "agent=auto" was the tri-state this key briefly had in review. It never
      // shipped, so there is nothing to migrate — but the spelling is in the
      // issue text people copy from, so say where it went rather than just "no".
      const hint =
        dottedPath === "sections.agent" && rawValue.toLowerCase() === "auto"
          ? "\nagent is a boolean now: the old 'auto' is the default, i.e. agent=true"
          : "";
      throw new Error(
        `invalid value for ${name}: ${rawValue} (expected true or false)${hint}\n${USAGE}`
      );
    }
    setAtPath(settings, dottedPath, parsed);
    return;
  }
  // Closed enum: matched case-insensitively and stored canonically lowercased,
  // so the file the renderer reads only ever holds one spelling. The error
  // echoes what the user actually typed, not the folded form.
  const normalised = rawValue.toLowerCase();
  if (!VALID_VALUES[dottedPath].includes(normalised)) {
    throw new Error(
      `invalid value for ${name}: ${rawValue} (expected ${VALID_VALUES[
        dottedPath
      ].join(" or ")})\n${USAGE}`
    );
  }
  setAtPath(settings, dottedPath, normalised);
}

// Read-modify-write: setting one key always preserves the others.
function setKey(dottedPath, value) {
  const settings = readSettings();
  setAtPath(settings, dottedPath, value);
  writeSettings(settings);
  return settings;
}

// Read-modify-write, mirroring setKey: dropping the badge preserves everything else.
function clearKey(dottedPath) {
  const settings = readSettings();
  deleteAtPath(settings, dottedPath);
  writeSettings(settings);
  return settings;
}

function toggleKey(name) {
  const dottedPath = resolvePath(name);
  const settings = readSettings();
  const current = getAtPath(settings, dottedPath);
  if (isSectionPath(dottedPath)) return setKey(dottedPath, !current);
  const [first, second] = VALID_VALUES[dottedPath];
  return setKey(dottedPath, current === first ? second : first);
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
  const settings =
    value === CLEAR_FLAG ? clearKey("badge") : setKey("badge", value);
  consumeLegacyBadgeFile();
  return settings;
}

// Legacy single-key entrypoint: value undefined/"" -> toggle, valid value -> set.
// Throws on invalid input. Kept because the statusline-style shell alias and the
// /statusline-style shim both front it.
function applySetting(key, value) {
  if (FREE_FORM_KEYS.includes(key)) return applyBadge(value);
  if (!LEGACY_KEYS.includes(key)) {
    throw new Error(`invalid key: ${key}\n${USAGE}`);
  }
  if (!value) return toggleKey(key);
  const dottedPath = resolvePath(key);
  // Validate through the shared path, then commit — applyAssignment mutates a
  // throwaway copy, so an invalid value never reaches the file.
  const probe = readSettings();
  applyAssignment(probe, key, value);
  return setKey(dottedPath, getAtPath(probe, dottedPath));
}

// Parse "--reset" / "--reset=a,b" into the list of canonical paths to drop, or
// undefined for a full reset. Throws on an unknown name.
function parseResetTargets(arg) {
  if (arg === RESET_FLAG) return undefined;
  const names = arg
    .slice(`${RESET_FLAG}=`.length)
    .split(",")
    .map((name) => name.trim())
    .filter((name) => name !== "");
  if (names.length === 0) {
    throw new Error(`${RESET_FLAG}= requires at least one key\n${USAGE}`);
  }
  return names.map(resolvePathOrThrow);
}

// A reset never touches the badge, targeted or full: it is not on this surface at
// all, so "--reset=badge" is rejected upstream and a full reset carries the badge
// through untouched. Blanking profile identity from a command that reads as
// "restore defaults" would be a destructive surprise; create-statusline-badge.sh
// and the legacy `badge --clear` subcommand are the only things that clear it.
function applyReset(targets) {
  if (targets === undefined) {
    const badge = readSettings().badge;
    const settings = defaults();
    if (badge !== undefined) settings.badge = badge;
    writeSettings(settings);
    return settings;
  }
  const settings = readSettings();
  const fresh = defaults();
  for (const dottedPath of targets) {
    setAtPath(settings, dottedPath, getAtPath(fresh, dottedPath));
  }
  writeSettings(settings);
  return settings;
}

// The /statusline-options entrypoint. No arguments -> pure read, no write at all.
// Assignments are validated in full against a copy BEFORE the write, so a typo in
// the third pair cannot leave the first two applied.
function applyOptions(args) {
  if (args.length === 0) return { settings: readSettings(), json: false, wrote: false };
  if (args.length === 1 && args[0] === JSON_FLAG) {
    return { settings: readSettings(), json: true, wrote: false };
  }

  const resetArg = args.find(
    (arg) => arg === RESET_FLAG || arg.startsWith(`${RESET_FLAG}=`)
  );
  if (resetArg !== undefined) {
    if (args.length > 1) {
      throw new Error(`${RESET_FLAG} takes no other arguments\n${USAGE}`);
    }
    return { settings: applyReset(parseResetTargets(resetArg)), json: false, wrote: true };
  }

  const settings = readSettings();
  for (const arg of args) {
    const separator = arg.indexOf("=");
    if (separator <= 0) {
      throw new Error(`expected <key>=<value>, got: ${arg}\n${USAGE}`);
    }
    // Split on the FIRST "=" only: a badge value legitimately contains more.
    applyAssignment(settings, arg.slice(0, separator), arg.slice(separator + 1));
  }
  // No consumeLegacyBadgeFile here: `options` cannot write the badge, so it has
  // no business deleting the file the badge may still live in. That belongs to
  // the paths that actually own a badge write.
  writeSettings(settings);
  return { settings, json: false, wrote: true };
}

function formatState(settings, key) {
  if (key === "badge") {
    return settings.badge === undefined
      ? "statusline: badge cleared"
      : "statusline: badge set";
  }
  const styleLabel = settings.style === "verbose" ? "extended ON" : "compact";
  const weeklyLabel = settings.sections.seven_day ? "ON" : "OFF";
  return `statusline: ${styleLabel}, weekly ${weeklyLabel}`;
}

function formatOptions(settings) {
  // The badge is shown but not settable here — see OPTION_PATHS. Reported as
  // set/none rather than raw: it is an ANSI string, and dumping it into a config
  // listing would repaint the rest of the output.
  const lines = [
    `style: ${settings.style}`,
    `badge: ${settings.badge === undefined ? "(none)" : "set (via create-statusline-badge.sh)"}`,
    "sections:",
  ];
  for (const key of Object.keys(SECTION_DEFAULTS)) {
    lines.push(`  ${key}: ${settings.sections[key] ? "on" : "off"}`);
  }
  return lines.join("\n");
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
    return SCALAR_DEFAULTS.style;
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

  const settings = defaults();
  if (style !== undefined) settings.style = style;
  if (badge !== undefined) settings.badge = badge;
  writeSettings(settings);

  // Every predecessor is dead once the new file exists.
  fs.rmSync(stylePathFor(), { force: true });
  fs.rmSync(legacyFlagPathFor(), { force: true });
  consumeLegacyBadgeFile();
}

// ponytail: self-check runs against a temp config dir so it never touches the
// real settings. Invoke with `node statusline-settings.js --self-check`.
function selfCheck() {
  const assert = require("assert");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "statusline-settings-"));
  // Clear the higher-precedence override before pinning the temp dir: this check
  // steers itself with CLAUDE_CONFIG_DIR, so an ambient STATUSLINE_CONFIG_DIR
  // would now outrank it and point every assertion below at the developer's real
  // settings file.
  delete process.env.STATUSLINE_CONFIG_DIR;
  process.env.CLAUDE_CONFIG_DIR = tmp;
  const read = () => readSettings();

  // --- config dir resolution (contract with the renderer's resolve_config_dir) --
  {
    const a = fs.mkdtempSync(path.join(os.tmpdir(), "statusline-cfg-a-"));
    const b = fs.mkdtempSync(path.join(os.tmpdir(), "statusline-cfg-b-"));
    // STATUSLINE_CONFIG_DIR outranks CLAUDE_CONFIG_DIR
    process.env.STATUSLINE_CONFIG_DIR = a;
    process.env.CLAUDE_CONFIG_DIR = b;
    assert.strictEqual(configDir(), a);
    // an empty value reads as unset and falls through, as `[ -n "${VAR:-}" ]` does
    process.env.STATUSLINE_CONFIG_DIR = "";
    assert.strictEqual(configDir(), b);
    // neither set: ~/.claude
    delete process.env.STATUSLINE_CONFIG_DIR;
    delete process.env.CLAUDE_CONFIG_DIR;
    assert.strictEqual(
      configDir(),
      path.join(os.homedir() || process.env.HOME || process.env.USERPROFILE, ".claude")
    );
    fs.rmSync(a, { recursive: true, force: true });
    fs.rmSync(b, { recursive: true, force: true });
    process.env.CLAUDE_CONFIG_DIR = tmp;
  }
  // defaults apply when the file is absent
  assert.deepStrictEqual(read(), defaults());
  assert.strictEqual(read().sections.seven_day, false);
  assert.strictEqual(read().sections.agent, true);
  // explicit values are forced
  assert.strictEqual(applySetting("style", "verbose").style, "verbose");
  assert.strictEqual(applySetting("weekly", "on").sections.seven_day, true);
  // setting one key preserves the others
  assert.strictEqual(applySetting("style", "compact").sections.seven_day, true);
  // omitted value toggles
  assert.strictEqual(applySetting("style").style, "verbose");
  assert.strictEqual(applySetting("weekly").sections.seven_day, false);
  // invalid input throws and leaves state untouched
  assert.throws(() => applySetting("style", "bogus"));
  assert.throws(() => applySetting("bogus", "on"));
  assert.strictEqual(read().style, "verbose");
  // malformed JSON falls back to defaults instead of throwing
  fs.writeFileSync(settingsPathFor(), "{not json");
  assert.deepStrictEqual(read(), defaults());
  // the superseded "weekly" alias, in both shapes ever written
  fs.writeFileSync(settingsPathFor(), JSON.stringify({ weekly: "on" }));
  assert.strictEqual(read().sections.seven_day, true);
  fs.writeFileSync(settingsPathFor(), JSON.stringify({ weekly: true }));
  assert.strictEqual(read().sections.seven_day, true);
  fs.writeFileSync(settingsPathFor(), JSON.stringify({ weekly: "off" }));
  assert.strictEqual(read().sections.seven_day, false);
  // the canonical key beats the alias, and a write drops the alias for good
  fs.writeFileSync(
    settingsPathFor(),
    JSON.stringify({ weekly: "on", sections: { seven_day: false } })
  );
  assert.strictEqual(read().sections.seven_day, false);
  writeSettings(read());
  assert.ok(!("weekly" in parseSettingsFile()));
  // options: multi-set, and a bad pair aborts the whole batch
  fs.rmSync(settingsPathFor(), { force: true });
  applyOptions(["style=verbose", "git=false", "agent=false"]);
  assert.strictEqual(read().style, "verbose");
  assert.strictEqual(read().sections.git, false);
  assert.strictEqual(read().sections.agent, false);
  // The superseded tri-state spelling is rejected, and says where it went.
  assert.throws(() => applyOptions(["agent=auto"]), /agent=true/);
  assert.throws(() => applyOptions(["style=compact", "bogus=1"]));
  // Closed vocabularies fold case and normalise on the way in; 1/0 count too.
  assert.strictEqual(applyOptions(["style=VERBOSE"]).settings.style, "verbose");
  assert.strictEqual(applyOptions(["agent=Off"]).settings.sections.agent, false);
  assert.strictEqual(applyOptions(["agent=1"]).settings.sections.agent, true);
  assert.strictEqual(applyOptions(["git=0"]).settings.sections.git, false);
  // options cannot write the badge, and says where to go instead
  assert.throws(() => applyOptions(["badge=x"]), /create-statusline-badge/);
  assert.throws(() => applyOptions([`${RESET_FLAG}=badge`]), /create-statusline-badge/);
  assert.strictEqual(read().style, "verbose", "a bad pair must not half-apply");
  // options: "clock" and "sections.clock" both reach session_start_date
  applyOptions(["clock=false"]);
  assert.strictEqual(read().sections.session_start_date, false);
  applyOptions(["sections.clock=true"]);
  assert.strictEqual(read().sections.session_start_date, true);
  // options: a section name that is not one must not wear the sections. prefix
  assert.throws(() => applyOptions(["sections.style=verbose"]));
  // reset: selected keys only
  applyReset(["sections.git"]);
  assert.strictEqual(read().sections.git, true);
  assert.strictEqual(read().style, "verbose", "a targeted reset touches nothing else");
  // badge: set/clear preserves the other keys, and no badge key means no badge
  const rawBadge = "\x1b[1;35m[work]\x1b[0m ";
  assert.strictEqual(applySetting("badge", rawBadge).badge, rawBadge);
  // round-trip through the file must be byte-identical: a mangled badge renders
  // as literal escape text instead of erroring.
  assert.strictEqual(read().badge, rawBadge);
  assert.strictEqual(applySetting("style", "compact").badge, rawBadge);
  // a full reset restores every option but must NOT blank the badge
  assert.strictEqual(applyReset(undefined).badge, rawBadge);
  assert.strictEqual(read().style, "compact");
  assert.strictEqual(read().sections.seven_day, false);
  // the badge survives an options write it was never part of
  assert.strictEqual(applyOptions(["style=verbose"]).settings.badge, rawBadge);
  // ...and the legacy subcommand is still its write path, untouched
  assert.strictEqual(applySetting("badge", CLEAR_FLAG).badge, undefined);
  // badge has no toggle: an omitted value is an error
  assert.throws(() => applySetting("badge"));
  // empty badge in the file reads as absent (renderer falls back to the .txt)
  writeSettings({ ...defaults(), badge: "" });
  assert.strictEqual(read().badge, undefined);
  // migration: ".statusline-style" seeds the new file and is consumed
  fs.rmSync(settingsPathFor(), { force: true });
  fs.writeFileSync(stylePathFor(), "verbose\n");
  migrateLegacySettings();
  assert.strictEqual(read().style, "verbose");
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
  assert.strictEqual(read().style, "verbose");
  assert.ok(!fs.existsSync(legacyFlagPathFor()));
  // migration: "statusline-badge.txt" folds into the badge key and is consumed
  fs.rmSync(settingsPathFor(), { force: true });
  fs.writeFileSync(legacyBadgePathFor(), rawBadge);
  migrateLegacySettings();
  assert.strictEqual(read().badge, rawBadge);
  assert.ok(!fs.existsSync(legacyBadgePathFor()));
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log("statusline-settings: self-check OK");
}

function main() {
  const key = process.argv[2];
  if (key === "options") {
    const result = applyOptions(process.argv.slice(3));
    console.log(
      result.json ? JSON.stringify(result.settings, null, 2) : formatOptions(result.settings)
    );
    return;
  }
  console.log(formatState(applySetting(key, process.argv[3]), key));
}

if (require.main === module) {
  if (process.argv[2] === "--self-check") {
    selfCheck();
  } else {
    try {
      migrateLegacySettings();
      main();
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
  applyOptions,
  applyReset,
  migrateLegacySettings,
  defaults,
  SECTION_DEFAULTS,
  SCALAR_DEFAULTS,
};
