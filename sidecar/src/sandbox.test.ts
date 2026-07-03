import { test } from "node:test";
import assert from "node:assert/strict";
import { readPathAllowed, searchRootAllowed, mcpPermission } from "./agent.js";

const HOME = "/home/u";

/// Fake realpath: `/home/u/Documents/link` (and anything beneath it) is a
/// symlink to `/home/u/.ssh`. Everything else resolves to itself.
const LINK = "/home/u/Documents/link";
const linkFs = (p: string): string => {
  if (p === LINK) return "/home/u/.ssh";
  if (p.startsWith(LINK + "/")) return "/home/u/.ssh/" + p.slice(LINK.length + 1);
  return p;
};
/// Identity realpath: keeps the lexical-logic tests pure and independent of the
/// host filesystem (the real realpathSync would resolve /home via macOS autofs).
const idFs = (p: string): string => p;

test("Read allows non-sensitive files under home (absolute and relative)", () => {
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/Documents/notes.txt", idFs), true);
  assert.equal(readPathAllowed(HOME, HOME, "Documents/notes.txt", idFs), true);
});

test("Read denies sensitive paths, including .codex", () => {
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.codex/auth.json", idFs), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.codex-global-state.json", idFs), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.ssh/id_rsa", idFs), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.claude.json", idFs), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.config/gh/hosts.yml", idFs), false);
});

test("Read denies case variants on a case-insensitive filesystem", () => {
  // macOS APFS default: ~/.SSH/id_rsa reaches the same file as ~/.ssh/id_rsa.
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.SSH/id_rsa", idFs), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.Codex/auth.json", idFs), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/Library/keychains/x", idFs), false);
});

test("Read still allows a distinct sibling that only shares a denied prefix", () => {
  // .ssh-notes is not under .ssh — the path-separator guard must hold.
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.ssh-notes/todo.txt", idFs), true);
});

test("search denies case variants of a denied root", () => {
  assert.equal(searchRootAllowed(HOME, HOME, "/home/u/.SSH", idFs), false);
});

test("Read denies paths outside home", () => {
  assert.equal(readPathAllowed(HOME, HOME, "/etc/passwd", idFs), false);
  assert.equal(readPathAllowed(HOME, HOME, "../../etc/passwd", idFs), false);
  assert.equal(readPathAllowed(HOME, HOME, 42, idFs), false); // non-string
});

test("search denies an unscoped home root (recursive-pattern exfil vector)", () => {
  // The bypass the review flagged: Glob {path:$HOME, pattern:".ssh/**"} and
  // Grep {path:$HOME, pattern:"PRIVATE KEY"} pass a path check but recurse into
  // secrets. Blocking the root closes it regardless of pattern.
  assert.equal(searchRootAllowed(HOME, HOME, HOME, idFs), false);
  assert.equal(searchRootAllowed(HOME, HOME, undefined, idFs), false); // defaults to cwd = home
  assert.equal(searchRootAllowed(HOME, HOME, "", idFs), false);
});

test("search denies roots at or above any denied dir", () => {
  assert.equal(searchRootAllowed(HOME, HOME, "/home/u/.ssh", idFs), false); // inside denied
  assert.equal(searchRootAllowed(HOME, HOME, "/home/u/.config", idFs), false); // above .config/gh
});

test("search allows a scoped subtree with no secrets beneath", () => {
  assert.equal(searchRootAllowed(HOME, HOME, "/home/u/Documents", idFs), true);
  assert.equal(searchRootAllowed(HOME, HOME, "Documents", idFs), true);
});

test("Read denies a symlink (and paths beneath it) pointing into a denied dir", () => {
  // The bypass: a lexical check sees /home/u/Documents/link under $HOME and not
  // under .ssh, so it would allow it; realResolve follows the link to .ssh.
  assert.equal(readPathAllowed(HOME, HOME, LINK, linkFs), false);
  assert.equal(readPathAllowed(HOME, HOME, LINK + "/id_rsa", linkFs), false);
});

test("search denies a root that symlinks into a denied dir", () => {
  assert.equal(searchRootAllowed(HOME, HOME, LINK, linkFs), false);
  assert.equal(searchRootAllowed(HOME, HOME, LINK + "/keys", linkFs), false);
});

test("Read still allows a symlink resolving to a non-sensitive location", () => {
  const okFs = (p: string): string =>
    p === "/home/u/Documents/alias" ? "/home/u/Documents/real" : p;
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/Documents/alias", okFs), true);
});

test("MCP gate denies action tools when actions are disabled", () => {
  for (const t of [
    "mcp__claude_ai_Slack__slack_send_message",
    "mcp__claude_ai_Atlassian_Rovo__createJiraIssue",
    "mcp__claude_ai_Atlassian_Rovo__addCommentToJiraIssue",
    "mcp__unison__run", // the reported hole: no verb in the old denylist
    "mcp__unison__lib-install", // ditto
    "mcp__unison__update-definitions",
    "mcp__claude_ai_Datadog__ddsql_upsert_saved_query", // action wins over "query"
  ]) {
    assert.equal(mcpPermission(t, false), "deny", t);
  }
});

test("MCP gate allows read/search tools when actions are disabled", () => {
  for (const t of [
    "mcp__claude_ai_Slack__slack_search_public",
    "mcp__claude_ai_Slack__slack_read_thread",
    "mcp__claude_ai_Atlassian_Rovo__getJiraIssue",
    "mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql",
    "mcp__claude_ai_Datadog__get_datadog_metric",
    "mcp__unison__list-project-definitions",
    "mcp__unison__view-definitions",
    "mcp__unison__docs",
  ]) {
    assert.equal(mcpPermission(t, false), "allow", t);
  }
});

test("MCP gate denies action verbs embedded mid-camelCase (issue #42 fail-open)", () => {
  // The verb sits after a lower-case letter and is upper-cased, so it dodges the
  // `^ / _ / -` word anchor; a leading read verb (fetch/get/search/view) would
  // otherwise wave the tool through. Must fail closed.
  for (const t of [
    "mcp__x__fetchAndDelete",
    "mcp__x__getOrDeleteItem",
    "mcp__x__searchAndUpdate",
    "mcp__x__viewAndReset",
    "mcp__x__read_and_delete", // snake-cased sibling — already correct
  ]) {
    assert.equal(mcpPermission(t, false), "deny", t);
  }
});

test("MCP gate still allows read-only camelCase tools (no embedded action verb)", () => {
  for (const t of [
    "mcp__x__getItem",
    "mcp__x__searchMessages",
    "mcp__x__getUpdates", // "update" is not a whole word here (trailing "s")
    "mcp__x__listChannels",
  ]) {
    assert.equal(mcpPermission(t, false), "allow", t);
  }
});

test("MCP gate fails closed for unrecognised tools when actions are disabled", () => {
  assert.equal(mcpPermission("mcp__some_server__frobnicate", false), "deny");
});

test("MCP gate allows everything when actions are enabled", () => {
  assert.equal(mcpPermission("mcp__claude_ai_Slack__slack_send_message", true), "allow");
  assert.equal(mcpPermission("mcp__unison__run", true), "allow");
});
