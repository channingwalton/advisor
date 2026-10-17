import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { HookInput } from "@anthropic-ai/claude-agent-sdk";
import {
  readPathAllowed, searchRootAllowed, mcpPermission, normaliseVerbName, bareMcpName, toolDecision, sandboxGate,
  type SandboxPolicy,
} from "./agent.js";

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

// Real symlinks in a synthetic home: credentials may be directories, files,
// or beneath a symlinked parent. Never touch the user's actual credentials.
function symlinkedHome(t: TestContext): string {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-claude-sb-")));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  for (const dir of ["dotfiles/.ssh", "dotfiles/cli/gh", "dotfiles/.ssh-notes", "Documents"]) {
    fs.mkdirSync(path.join(home, dir), { recursive: true });
  }
  for (const file of ["dotfiles/.ssh/synthetic-key", "dotfiles/npm-token", "dotfiles/cli/gh/hosts.yml"]) {
    fs.writeFileSync(path.join(home, file), "synthetic credential");
  }
  for (const file of ["Documents/notes.txt", "dotfiles/.ssh-notes/todo.txt"]) {
    fs.writeFileSync(path.join(home, file), "ordinary notes");
  }
  for (const [alias, target] of [
    [".ssh", "dotfiles/.ssh"],
    [".npmrc", "dotfiles/npm-token"],
    [".config", "dotfiles/cli"],
    ["keys", ".ssh"],
    ["notes", "Documents"],
  ]) {
    fs.symlinkSync(target, path.join(home, alias));
  }
  return home;
}

test("#sandbox-symlink-read denies credential aliases and resolved targets", (t) => {
  const home = symlinkedHome(t);
  const denied = [
    ".ssh", ".ssh/synthetic-key", "dotfiles/.ssh/synthetic-key", "keys/synthetic-key",
    ".ssh/missing/key", "dotfiles/.ssh/missing/key",
    ".npmrc", "dotfiles/npm-token", ".config/gh/hosts.yml", "dotfiles/cli/gh/hosts.yml",
  ];
  assert.deepEqual(denied.filter((p) => readPathAllowed(home, home, path.join(home, p))), []);
  assert.deepEqual(denied.filter((p) => readPathAllowed(home, home, p)), []);
});

test("#sandbox-symlink-search denies roots containing resolved credentials", (t) => {
  const home = symlinkedHome(t);
  const denied = [".", ".ssh", "keys", "dotfiles/.ssh", "dotfiles", ".config", "dotfiles/cli"];
  assert.deepEqual(denied.filter((p) => searchRootAllowed(home, home, path.join(home, p))), []);
  assert.deepEqual(denied.filter((p) => searchRootAllowed(home, home, p)), []);
});

test("#sandbox-symlink-permitted keeps ordinary files and scoped searches accessible", (t) => {
  const home = symlinkedHome(t);
  for (const dir of ["Documents", "notes", "dotfiles/.ssh-notes"]) {
    const file = path.join(dir, dir.endsWith(".ssh-notes") ? "todo.txt" : "notes.txt");
    assert.equal(readPathAllowed(home, home, path.join(home, file)), true, file);
    assert.equal(readPathAllowed(home, home, file), true, file);
    assert.equal(searchRootAllowed(home, home, path.join(home, dir)), true, dir);
    assert.equal(searchRootAllowed(home, home, dir), true, dir);
  }
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

// Code review 2026-10-17: `share` sat in the read allowlist (sharing grants a
// third party access), the action list lacked replace/insert/append/submit/
// save/modify/put and more, and a combined name passed on its leading read verb
// alone. Now a conjunction denies outright, whatever the second verb.
test("MCP gate denies sharing, the mutating verbs it lacked, and any conjunction", () => {
  for (const t of [
    "mcp__gdrive__share_file",
    "mcp__x__shareDashboard",
    "mcp__x__comment_on_issue",
    "mcp__x__replyToThread",
    "mcp__gmail__mark_read",
    "mcp__x__patch_issue",
    "mcp__x__put_object",
    "mcp__x__replace_text",
    "mcp__x__insertRow",
    "mcp__x__save_draft",
    "mcp__x__purge_history", // unknown-to-the-old-list verb on a read noun
    "mcp__x__trash_docs",
    "mcp__x__sync_schema",
    "mcp__x__notify_on_query",
    // Conjunctions: the second verb need not be on any list.
    "mcp__gdocs__find_and_replace",
    "mcp__x__get_or_insert",
    "mcp__slack__read_and_reply",
    "mcp__gmail__fetchAndMarkRead",
    "mcp__jira__getIssueAndComment",
    "mcp__x__list_then_patch",
    "mcp__x__get_and_frobnicate",
    "mcp__x__search_and_escalate",
    "mcp__x__fetch-and-sync",
    // An acronym run must not hide the verb after it.
    "mcp__x__getHTTPPutURL",
    "mcp__x__fetchHTTPSave",
    // Nor may any other separator a tool name can use.
    "mcp__x__search.delete",
    "mcp__x__files/delete_list",
    "mcp__x__get:delete",
    "mcp__x__get delete",
    // A `__` inside the tool's own name is not the server separator.
    "mcp__x__delete__list",
    // Verbs the lists lacked, on a read verb or noun.
    "mcp__x__kill_process_list",
    "mcp__x__revert_diff",
    "mcp__x__destroy_view",
    "mcp__x__open_issue",
    "mcp__x__commit_changes",
    "mcp__x__release_version",
    "mcp__x__resolve_thread",
    // A service prefix does not make an ambiguous verb a noun.
    "mcp__gmail__gmail_mark_as_read",
    "mcp__slack__slack_mark_read",
    "mcp__gdrive__gdrive_share_file_get_link",
    // Verbs built on listed ones, and the rest the lists lacked.
    "mcp__x__truncate_history",
    "mcp__x__rewrite_docs",
    "mcp__x__overwrite_docs",
    "mcp__x__migrate_schema",
    "mcp__x__undelete_doc",
    "mcp__x__prepend_history",
    // A read noun first does not vouch for the verb after it.
    "mcp__x__schema_migrate",
    "mcp__x__doc_share",
    "mcp__x__info_push",
    // Read verbs are whole words.
    "mcp__x__listen_for_events",
    "mcp__x__getaway_booking",
    // The recorded cost of the conjunction rule: a read tool named with one.
    "mcp__slack__slack_search_public_and_private",
  ]) {
    assert.equal(mcpPermission(t, false), "deny", t);
  }
});

test("MCP gate keeps allowing reads named after a noun that is also an action verb", () => {
  for (const t of [
    "mcp__x__get_comment",
    "mcp__x__getComment",
    "mcp__jira__get_issue_comment",
    "mcp__x__get_comments",
    "mcp__x__list_replies",
    "mcp__x__get_reply",
    "mcp__github__get_commit_patch",
    "mcp__github__list_deploy_keys",
    "mcp__x__list_push_notifications",
    "mcp__x__find_duplicate_issues",
    "mcp__gdrive__get_share_link",
    "mcp__gdrive__list_shared_drives",
    "mcp__gdrive__sharedWithMe",
    "mcp__x__get_copy_status",
    "mcp__x__get_markdown",
    "mcp__x__list_bookmarks",
    "mcp__datadog__get_saved_queries",
    "mcp__x__get_input_schema",
    "mcp__x__search_copyright_notices",
    "mcp__x__get_open_issues",
    "mcp__github__get_release",
    "mcp__jira__jira_get_issue_comment", // a read verb before the ambiguous one
    // Read nouns as the whole name, first word or last word.
    "mcp__unison__docs",
    "mcp__x__history",
    "mcp__x__schema_info",
    "mcp__slack__conversations_history",
    "mcp__claude_ai_Atlassian_Rovo__atlassianUserInfo",
    "mcp__x__table_schema",
    "mcp__x__getHTTPHeaders",
  ]) {
    assert.equal(mcpPermission(t, false), "allow", t);
  }
});

test("normaliseVerbName splits camelCase and acronym runs into lower-case words, on any separator", () => {
  assert.equal(normaliseVerbName("fetchAndDelete"), "fetch_and_delete");
  assert.equal(normaliseVerbName("getHTTPPutURL"), "get_http_put_url");
  assert.equal(normaliseVerbName("slack_search_public"), "slack_search_public");
  assert.equal(normaliseVerbName("issues.delete-all/now"), "issues_delete_all_now");
  // A pluralised acronym comes out mangled, but the leading verb survives.
  assert.equal(normaliseVerbName("getURLs"), "get_ur_ls");
});

test("bareMcpName strips exactly the mcp__<server>__ prefix", () => {
  assert.equal(bareMcpName("mcp__claude_ai_Slack__slack_send_message"), "slack_send_message");
  assert.equal(bareMcpName("mcp__x__delete__list"), "delete__list");
  assert.equal(bareMcpName("Read"), "Read");
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

const POLICY: SandboxPolicy = { home: HOME, cwd: HOME, allowMcpActions: false, realpath: idFs };
const decide = (tool: string, input: unknown, policy = POLICY) => toolDecision(tool, input, policy).behavior;

test("#sandbox-tool-allowlist allows web, read/search, ToolSearch and MCP resource tools", () => {
  // ToolSearch is how the CLI loads deferred connector tools — refusing it would
  // cut agents off from every MCP connector.
  for (const t of ["WebSearch", "WebFetch", "ToolSearch", "ListMcpResourcesTool", "ReadMcpResourceTool"]) {
    assert.equal(decide(t, {}), "allow", t);
  }
});

test("#sandbox-tool-allowlist refuses every other tool the CLI offers", () => {
  for (const t of [
    "Bash", "Write", "Edit", "NotebookEdit", "Agent", "Task", "Skill", "TaskCreate", "TeamCreate",
    "Workflow", "AskUserQuestion", "CronCreate", "ScheduleWakeup", "EnterWorktree", "SendMessage",
    "SomeFutureTool",
  ]) {
    assert.equal(decide(t, {}), "deny", t);
  }
});

test("#sandbox-tool-allowlist gates MCP tools through the connector policy", () => {
  assert.equal(decide("mcp__x__getItem", {}), "allow");
  assert.equal(decide("mcp__x__deleteItem", {}), "deny");
  assert.equal(decide("mcp__x__deleteItem", {}, { ...POLICY, allowMcpActions: true }), "allow");
});

test("#sandbox-explicit-paths Read needs an absolute or ~ path to a permitted file", () => {
  // A relative path resolves against the CLI's cwd, so the policy could judge a
  // different file than the one read. A leading ~ is the home directory, as the
  // CLI expands it.
  assert.equal(decide("Read", { file_path: "/home/u/Documents/notes.txt" }), "allow");
  assert.equal(decide("Read", { file_path: "~/Documents/notes.txt" }), "allow");
  assert.equal(decide("Read", { file_path: "Documents/notes.txt" }), "deny");
  assert.equal(decide("Read", { file_path: "~/.ssh/id_rsa" }), "deny");
  assert.equal(decide("Read", { file_path: "~root/notes.txt" }), "deny");
  assert.equal(decide("Read", { file_path: "/home/u/.ssh/id_rsa" }), "deny");
  assert.equal(decide("Read", {}), "deny");
  assert.equal(decide("Read", null), "deny");
});

test("#sandbox-explicit-paths Grep and Glob need an absolute, permitted root", () => {
  assert.equal(decide("Glob", { path: "/home/u/Documents", pattern: "*.md" }), "allow");
  assert.equal(decide("Grep", { path: "/home/u/Documents", pattern: "TODO" }), "allow");
  // The CLI passes a Glob/Grep `path` to the gate unexpanded.
  assert.equal(decide("Glob", { path: "~/Documents", pattern: "*.md" }), "allow");
  assert.equal(decide("Grep", { path: "~/Documents", pattern: "TODO" }), "allow");
  for (const input of [
    { pattern: "*.md" }, // no path: would search the CLI's cwd, not a checked root
    { path: "Documents", pattern: "*.md" },
    { path: "~/.ssh", pattern: "*" },
    { path: "~", pattern: "*" }, // the whole home: at or above every denied path
    { path: "/home/u/.ssh", pattern: "*" },
  ]) {
    assert.equal(decide("Glob", input), "deny", JSON.stringify(input));
    assert.equal(decide("Grep", { ...input, pattern: "x" }), "deny", JSON.stringify(input));
  }
});

test("#sandbox-glob-pattern refuses patterns that could search outside the checked root", () => {
  // The CLI searches an absolute pattern's own base directory, not `path`.
  for (const pattern of [
    "/home/u/.ssh/*", "~/.ssh/*", "../.ssh/*", "**/../../.ssh/*", "{/home/u/.ssh/*,x}", "{a,/etc/*}",
    "{a, /etc/*}", "{a, ~/.ssh/*}",
  ]) {
    assert.equal(decide("Glob", { path: "/home/u/Documents", pattern }), "deny", pattern);
    assert.equal(decide("Grep", { path: "/home/u/Documents", pattern: "KEY", glob: pattern }), "deny", pattern);
  }
});

test("#sandbox-glob-pattern keeps ordinary relative patterns", () => {
  // A ~ inside a name is literal (editor backups `*~`); only a leading one is home.
  for (const pattern of ["**/*.md", "*.{md,txt}", "notes/**/2026-*.md", "**/*~"]) {
    assert.equal(decide("Glob", { path: "/home/u/Documents", pattern }), "allow", pattern);
    assert.equal(decide("Grep", { path: "/home/u/Documents", pattern: "x", glob: pattern }), "allow", pattern);
  }
});

function preToolUse(tool_name: string, tool_input: unknown): HookInput {
  return {
    hook_event_name: "PreToolUse", tool_name, tool_input, tool_use_id: "toolu_1",
    session_id: "s", transcript_path: "/dev/null", cwd: HOME,
  } as HookInput;
}

test("#sandbox-sdk-gate the PreToolUse gate denies what the policy refuses", async () => {
  const denied: string[] = [];
  const gate = sandboxGate(POLICY, (tool) => denied.push(tool));
  const signal = new AbortController().signal;
  const out = await gate(preToolUse("Read", { file_path: "/home/u/.ssh/id_rsa" }), "toolu_1", { signal });
  const decision = (out as { hookSpecificOutput?: Record<string, unknown> }).hookSpecificOutput;
  assert.equal(decision?.hookEventName, "PreToolUse");
  assert.equal(decision?.permissionDecision, "deny");
  assert.match(String(decision?.permissionDecisionReason), /Access denied/);
  assert.deepEqual(denied, ["Read"]);
});

test("#sandbox-sdk-gate the PreToolUse gate passes permitted calls on without approving them", async () => {
  // No decision, not "allow": the call continues through the SDK's normal flow,
  // where canUseTool applies the same policy again.
  const gate = sandboxGate(POLICY);
  const signal = new AbortController().signal;
  const out = await gate(preToolUse("Read", { file_path: "/home/u/Documents/notes.txt" }), "toolu_1", { signal });
  assert.deepEqual(out, {});
});

test("#sandbox-sdk-gate the PreToolUse gate fails closed when the policy or its logging throws", async () => {
  // A rejected hook is non-blocking for the CLI, so any error must still deny.
  const signal = new AbortController().signal;
  const exploding = new Proxy({}, { get() { throw new Error("boom"); } });
  const out1 = await sandboxGate(POLICY)(preToolUse("Read", exploding), "toolu_1", { signal });
  assert.equal((out1 as { hookSpecificOutput?: { permissionDecision?: string } }).hookSpecificOutput?.permissionDecision, "deny");
  const loud = sandboxGate(POLICY, () => { throw new Error("log failed"); });
  const out2 = await loud(preToolUse("Read", { file_path: "/home/u/.ssh/id_rsa" }), "toolu_1", { signal });
  assert.equal((out2 as { hookSpecificOutput?: { permissionDecision?: string } }).hookSpecificOutput?.permissionDecision, "deny");
});
