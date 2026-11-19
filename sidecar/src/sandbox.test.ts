import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { HookInput } from "@anthropic-ai/claude-agent-sdk";
import { sandboxGate } from "./agent.js";
import {
  readPathAllowed, searchRootAllowed, readableRoots, readableFoldersNote, mcpPermission, normaliseVerbName, bareMcpName, toolDecision,
  type SandboxPolicy,
} from "./toolPolicy.js";

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

/// The denylist refused the call. The allowlist refuses most denied paths as
/// well, so a bare "deny" no longer shows that the denylist works.
const DENYLIST = /non-sensitive file or folder/;
const refusedBy = (reason: RegExp) => (tool: string, input: unknown, policy: SandboxPolicy): void => {
  const d = toolDecision(tool, input, policy);
  assert.equal(d.behavior, "deny", JSON.stringify(input));
  assert.match(d.behavior === "deny" ? d.message : "", reason, JSON.stringify(input));
};
const denylisted = refusedBy(DENYLIST);
/// The allowlist refused the call: the path is in no readable folder.
const notReadable = refusedBy(/folders that the user lists as readable/);

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

// GHSA-6xc8-f55f-jxqr: APFS folds more than ASCII case. `.ſsh` (long s), `.ßh`
// and `.conﬁg` (fi ligature) open `.ssh` and `.config`. The JS realpath keeps
// the spelling as given, so the lower-cased compare missed them. Skipped on a
// filesystem that does not fold names (CI runs the sidecar on Linux).
function foldingHome(t: TestContext): string | undefined {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-fold-sb-")));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  for (const dir of [".ssh", ".config/gh", "Documents"]) fs.mkdirSync(path.join(home, dir), { recursive: true });
  fs.writeFileSync(path.join(home, ".ssh", "synthetic-key"), "synthetic credential");
  fs.writeFileSync(path.join(home, ".config", "gh", "hosts.yml"), "synthetic credential");
  fs.writeFileSync(path.join(home, "Documents", "notes.txt"), "ordinary notes");
  if (fs.existsSync(path.join(home, ".ſsh"))) return home;
  t.skip("this filesystem does not fold names");
  return undefined;
}

test("#sandbox-fold-spelling denies each spelling that the filesystem folds to a denied path", (t) => {
  const home = foldingHome(t);
  if (home === undefined) return;
  const files = [".ſsh/synthetic-key", ".ßh/synthetic-key", ".SSH/synthetic-key", ".conﬁg/gh/hosts.yml", ".ſsh/missing/key"];
  assert.deepEqual(files.filter((p) => readPathAllowed(home, home, path.join(home, p))), []);
  const roots = [".ſsh", ".ßh", ".conﬁg", ".conﬁg/gh"];
  assert.deepEqual(roots.filter((p) => searchRootAllowed(home, home, path.join(home, p))), []);
  const policy: SandboxPolicy = { home, cwd: home, allowMcpActions: false, readableFolders: ["~/Documents"] };
  denylisted("Read", { file_path: "~/.ſsh/synthetic-key" }, policy);
  denylisted("Glob", { path: "~/.conﬁg", pattern: "**" }, policy);
  // Control: an ordinary file in the same home is still readable.
  assert.equal(toolDecision("Read", { file_path: "~/Documents/notes.txt" }, policy).behavior, "allow");
  // A readable folder listed in another case matches, because the stored
  // names are compared.
  const lower: SandboxPolicy = { ...policy, readableFolders: ["~/documents"] };
  assert.equal(toolDecision("Read", { file_path: "~/DOCUMENTS/notes.txt" }, lower).behavior, "allow");
  assert.equal(toolDecision("Glob", { path: "~/Documents", pattern: "*" }, lower).behavior, "allow");
  // A readable folder listed in a folded spelling of a denied path is refused.
  assert.deepEqual(readableRoots(home, ["~/.ſsh", "~/.ßh", "~/.conﬁg/gh", "~/.ſsh/sub"]), []);
});

test("#sandbox-fold-spelling a home folder stored in another Unicode form still reads", (t) => {
  // realpath(3) returns the stored form of each name (here NFD), while $HOME may
  // hold another form (NFC). The home check must not refuse every read.
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-nfd-sb-")));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const stored = path.join(base, "Jose\u0301");
  for (const dir of ["Documents", ".ssh"]) fs.mkdirSync(path.join(stored, dir), { recursive: true });
  fs.writeFileSync(path.join(stored, "Documents", "notes.txt"), "ordinary notes");
  fs.writeFileSync(path.join(stored, ".ssh", "id"), "synthetic credential");
  const home = path.join(base, "Jos\u00e9");
  if (!fs.existsSync(home) || fs.realpathSync.native(home) === home) {
    return t.skip("this filesystem does not store another Unicode form");
  }
  assert.equal(readPathAllowed(home, home, path.join(home, "Documents", "notes.txt")), true);
  assert.equal(searchRootAllowed(home, home, path.join(home, "Documents")), true);
  assert.equal(readPathAllowed(home, home, path.join(home, ".ssh", "id")), false);
  // A readable folder named in $HOME's form matches the stored form of a path.
  const policy: SandboxPolicy = {
    home, cwd: home, allowMcpActions: false, readableFolders: [path.join(home, "Documents")],
  };
  assert.equal(toolDecision("Read", { file_path: path.join(home, "Documents", "notes.txt") }, policy).behavior, "allow");
  assert.equal(toolDecision("Glob", { path: path.join(home, "Documents"), pattern: "*" }, policy).behavior, "allow");
});

test("#sandbox-symlink-read a symlink followed by .. is judged where the kernel goes", (t) => {
  // The kernel follows `k` before it applies `..`, so `~/Documents/k/../id`
  // opens `~/.ssh/id`. A lexical collapse first judged `~/Documents/id`.
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-dotdot-sb-")));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  for (const dir of [".ssh/keys", "Documents"]) fs.mkdirSync(path.join(home, dir), { recursive: true });
  fs.writeFileSync(path.join(home, ".ssh", "id"), "synthetic credential");
  fs.writeFileSync(path.join(home, "Documents", "notes.txt"), "ordinary notes");
  fs.symlinkSync(path.join(home, ".ssh", "keys"), path.join(home, "Documents", "k"));
  const viaLink = path.join(home, "Documents") + "/k/../id";
  assert.equal(fs.readFileSync(viaLink, "utf8"), "synthetic credential"); // the kernel's view
  assert.equal(readPathAllowed(home, home, viaLink), false);
  assert.equal(readPathAllowed(home, home, viaLink + "-missing"), false);
  assert.equal(searchRootAllowed(home, home, path.join(home, "Documents") + "/k/.."), false);
  const policy: SandboxPolicy = { home, cwd: home, allowMcpActions: false, readableFolders: ["~/Documents"] };
  denylisted("Read", { file_path: "~/Documents/k/../id" }, policy);
  // The lexical form too: the CLI normalises first, so it opens `~/.ssh/id` for
  // `~/deep/../.ssh/id`, while the kernel goes to `~/Documents/.ssh/id`.
  fs.symlinkSync(path.join(home, "Documents", "sub"), path.join(home, "deep"));
  fs.mkdirSync(path.join(home, "Documents", "sub"));
  const lexical = path.join(home, "deep") + "/../.ssh/id";
  assert.equal(readPathAllowed(home, home, lexical), false);
  assert.equal(searchRootAllowed(home, home, path.join(home, "deep") + "/../.ssh"), false);
  denylisted("Grep", { path: path.join(home, "deep") + "/../.ssh", pattern: "x" }, policy);
  // Control: an ordinary `..` still reads.
  assert.equal(readPathAllowed(home, home, path.join(home, ".ssh") + "/../Documents/notes.txt"), true);
});

test("#sandbox-credential-stores denies common credential stores beyond the first list", () => {
  const stores = [
    ".zsh_history", ".zsh_sessions/x.history", ".bash_history", ".bash_sessions/x", ".history",
    ".local/share/fish/fish_history", ".python_history", ".node_repl_history", ".psql_history",
    ".mysql_history", ".sqlite_history",
    ".config/gcloud/credentials.db", ".azure/msal_token_cache.json", ".oci/config", ".boto", ".s3cfg",
    ".terraform.d/credentials.tfrc.json", ".terraformrc", ".vault-token", ".config/doctl/config.yaml",
    ".config/op/config", ".password-store/x.gpg",
    ".pypirc", ".pgpass", ".cargo/credentials", ".cargo/credentials.toml", ".gem/credentials",
    ".m2/settings.xml", ".ivy2/.credentials", ".sbt/.credentials", ".gradle/gradle.properties",
    ".yarnrc.yml", ".config/hub", ".config/glab-cli/config.yml",
    ".cursor/mcp.json", ".codeium/windsurf/mcp_config.json", ".config/zed/settings.json",
    "Library/Application Support/Claude/claude_desktop_config.json",
    "Library/Application Support/Google/Chrome/Default/Login Data",
    "Library/Application Support/Firefox/Profiles/x/logins.json",
    "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
    "Library/Application Support/Microsoft Edge/Default/Login Data",
    "Library/Application Support/Arc/User Data/Default/Cookies",
    "Library/Application Support/Vivaldi/Default/Login Data",
    "Library/Application Support/com.operasoftware.Opera/Login Data",
    "Library/Safari/History.db",
    ".config/git/credentials", ".config/github-copilot/apps.json", ".yarnrc", ".zhistory",
    "Library/Application Support/Google/Chrome Beta/Default/Login Data",
    "Library/Application Support/Google/Chrome Canary/Default/Cookies",
    "Library/Application Support/Chromium/Default/Login Data",
    "Library/Application Support/Slack/Cookies", "Library/Application Support/discord/Local Storage/x",
    "Library/Application Support/Code/User/globalStorage/state.vscdb",
    "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
  ];
  assert.deepEqual(stores.filter((p) => readPathAllowed(HOME, HOME, path.join(HOME, p), idFs)), []);
  // Siblings stay readable: the denylist names stores, not their parents.
  for (const p of [".config/git/config", ".cargo/config.toml", "Library/Application Support/Advisor/x"]) {
    assert.equal(readPathAllowed(HOME, HOME, path.join(HOME, p), idFs), true, p);
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

const POLICY: SandboxPolicy = {
  home: HOME, cwd: HOME, allowMcpActions: false, realpath: idFs, readableFolders: ["/home/u/Documents"],
};
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
  // The denylist refuses these, so its message shows it: the allowlist would
  // refuse each of them too.
  for (const input of [
    { file_path: "Documents/notes.txt" }, { file_path: "~/.ssh/id_rsa" }, { file_path: "~root/notes.txt" },
    { file_path: "/home/u/.ssh/id_rsa" }, {}, null,
  ]) {
    denylisted("Read", input, POLICY);
  }
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
    denylisted("Glob", input, POLICY);
    denylisted("Grep", { ...input, pattern: "x" }, POLICY);
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

test("#sandbox-glob-pattern refuses a pattern that spells `..`, `/` or `~` another way", () => {
  // `fs.globSync`, which Advisor's own Glob runs, reads `[.][.]` as `..` and
  // `\/etc` and `{x,}/etc` as `/etc` (seen 2026-11-14). The policy judges each
  // brace alternative, and each segment that a class, an escape or an extglob
  // can make `..`.
  for (const pattern of [
    "[.][.]/.ssh/*", "[.]./.ssh/*", ".[.]/.ssh/*", "\\.\\./.ssh/*", ".\\./.ssh/*", "{.,x}./.ssh/*", "{.}{.}/.ssh/*",
    "{x,.}{.,y}/.ssh/*", "sub/{.,x}./.ssh/*", "[--/][--/]/.ssh/*", "[!x][!x]/.ssh/*", "[[:punct:]][[:punct:]]/.ssh/*",
    "[.x][.x]/.ssh/*", "+(.)/.ssh/*", "@(.)@(.)/.ssh/*",
    // Brace groups that Node pairs again: a group with no comma, and a `}`
    // that closes nothing (code review 2026-11-14).
    ".{},.}/.ssh/*", ".{},}./.ssh/*", "{x},}/home/u/.ssh/*", "{.}x,}/home/u/.ssh/*", "{a}/*", "x}/*",
    // A nested extglob, and the POSIX equivalence and collating classes (code review 2026-11-14).
    "@(@(x)|.)@(@(x)|.)/.ssh/*", "[[=.=]][[=.=]]/.ssh/*", "[[.period.]][[.period.]]/.ssh/*",
    "\\/home/u/.ssh/*", "{x,}/home/u/.ssh/*", "{,}/home/u/.ssh/*", "{{x,},y}/home/u/.ssh/*", "[/]home/u/.ssh/*",
    "{x,}~/.ssh/*", "\\~/.ssh/*", "{~/.ssh/*", "{x,/etc/*",
    // A `\` that Node reads as `/` before it expands braces (code review 2026-11-14).
    "{x,\\}/home/u/.ssh/*", "{,\\}/home/u/.ssh/*", "sub\\{.,x}.\\{.,x}.\\.ssh/*", "\\./home/u/.ssh/*",
    // More alternatives or characters than the policy judges, and a class in a brace group.
    "{a,b}".repeat(7) + "/*", "x".repeat(257), "{[.,][.,],y}/.ssh/*",
  ]) {
    assert.equal(decide("Glob", { path: "/home/u/Documents", pattern }), "deny", pattern);
    assert.equal(decide("Grep", { path: "/home/u/Documents", pattern: "KEY", glob: pattern }), "deny", pattern);
  }
});

test("#sandbox-glob-pattern judges a long pattern quickly", () => {
  // The gate runs on the sidecar's only thread. A 1020-character pattern took
  // 1.2 s before the limits (code review 2026-11-14).
  for (const pattern of [
    "{a,b}".repeat(6) + "[".repeat(226), "{".repeat(238) + "{,}".repeat(6), "[".repeat(128) + "\\]".repeat(64),
    "{a,b}".repeat(6) + "[[:alpha:]".repeat(22), "{a,b}".repeat(6) + "[\\".repeat(113),
    "{a,b}".repeat(6) + "[[:".repeat(75),
  ]) {
    // About 2 ms each on an M-series Mac, and 40 ms with a scan of each class
    // to the end of its segment. The best of three runs, after one that
    // compiles the code, with room for a slow CI runner.
    decide("Glob", { path: "/home/u/Documents", pattern });
    let ms = Infinity;
    for (let run = 0; run < 3; run++) {
      const started = performance.now();
      decide("Glob", { path: "/home/u/Documents", pattern });
      ms = Math.min(ms, performance.now() - started);
    }
    assert.ok(ms < 50, `${pattern.slice(0, 40)}…: ${ms.toFixed(0)} ms`);
  }
});

test("#sandbox-glob-pattern keeps ordinary relative patterns", () => {
  // A ~ inside a name is literal (editor backups `*~`); only a leading one is home.
  for (const pattern of [
    "**/*.md", "*.{md,txt}", "notes/**/2026-*.md", "**/*~", ".obsidian/*", "**/.*", ".*", "*", "??.md", "[0-9]*.md",
    "[ab].md", "[!.]*", "{a,b}/*.md", "a{b,c}d/*", "[[:alpha:]]*.md", "[.]obsidian/*", "notes.d/*",
    "**/*.{[Mm][Dd],txt}", "**/*(1).md",
  ]) {
    assert.equal(decide("Glob", { path: "/home/u/Documents", pattern }), "allow", pattern);
    assert.equal(decide("Grep", { path: "/home/u/Documents", pattern: "x", glob: pattern }), "allow", pattern);
  }
});

// GHSA-6xc8-f55f-jxqr: a denylist fails open for each credential store that it
// does not name, so Read, Grep and Glob reach only the folders that the user
// lists as readable.
const readable = (...folders: string[]): SandboxPolicy => ({ ...POLICY, readableFolders: folders });

test("#sandbox-readable-folders reads only inside a readable folder", () => {
  const policy = readable("/home/u/Documents", "~/work");
  assert.equal(decide("Read", { file_path: "/home/u/Documents/notes.txt" }, policy), "allow");
  assert.equal(decide("Read", { file_path: "~/work/sub/plan.md" }, policy), "allow");
  assert.equal(decide("Glob", { path: "~/work", pattern: "**/*.md" }, policy), "allow");
  assert.equal(decide("Grep", { path: "/home/u/Documents", pattern: "TODO" }, policy), "allow");
  // In the home folder and in no named store, but in no readable folder: only
  // the allowlist refuses these.
  for (const file of [
    "/home/u/.config/rclone/rclone.conf", "/home/u/notes.txt", "/home/u/Documentsx/a.txt",
    "/home/u/Library/Mobile Documents/x.md",
  ]) {
    notReadable("Read", { file_path: file }, policy);
  }
  for (const root of ["/home/u/.config/rclone", "~/Library/Mobile Documents", "/home/u/Documentsx"]) {
    notReadable("Glob", { path: root, pattern: "*" }, policy);
    notReadable("Grep", { path: root, pattern: "x" }, policy);
  }
});

test("#sandbox-readable-folders reads nothing when no folder is listed", () => {
  const policy = readable();
  notReadable("Read", { file_path: "/home/u/Documents/notes.txt" }, policy);
  notReadable("Glob", { path: "/home/u/Documents", pattern: "*" }, policy);
  notReadable("Grep", { path: "/home/u/Documents", pattern: "x" }, policy);
  // The other tools do not read local files, so they keep their own rules.
  assert.equal(decide("WebFetch", { url: "https://example.com" }, policy), "allow");
});

test("#sandbox-readable-folders refuses a listed folder at, under or above a denied path", () => {
  const roots = (...folders: string[]) => readableRoots(HOME, folders, idFs);
  // Above: the home folder, `/` and `~/Library` hold denied paths.
  // At or under: a denied path itself, or a folder in it.
  assert.deepEqual(roots(
    "/home/u", "~", "/", "/home", "/home/u/Library", "/home/u/.config", "/home/u/Library/Application Support",
    "/home/u/.ssh", "/home/u/.SSH", "/home/u/.ssh/sub", "~/.config/gh", "/home/u/Documents/..",
  ), []);
  // A folder inside a refused parent, beside the denied paths, is honoured.
  assert.deepEqual(roots("/home/u/Library/Mobile Documents"), ["/home/u/Library/Mobile Documents"]);
  const policy = readable("~/Library", "~/Library/Mobile Documents");
  assert.equal(decide("Read", { file_path: "~/Library/Mobile Documents/x.md" }, policy), "allow");
  notReadable("Read", { file_path: "~/Library/Preferences/x.plist" }, policy);
});

test("#sandbox-readable-folders matches a readable folder in its own letter case", () => {
  // On a case-sensitive volume `~/public` is another folder than `~/Public`.
  // (The fake filesystem keeps names as given, as such a volume does.)
  const policy = readable("/home/u/Public");
  notReadable("Read", { file_path: "/home/u/public/.env" }, policy);
  notReadable("Glob", { path: "~/PUBLIC", pattern: "*" }, policy);
  assert.equal(decide("Read", { file_path: "/home/u/Public/a.txt" }, policy), "allow");
});

test("#sandbox-readable-folders ignores a listed folder that is not absolute or not in the home folder", () => {
  assert.deepEqual(readableRoots(HOME, ["Documents", "", "~root/x", "/etc", "/Volumes/Disk/notes"], idFs), []);
  // The home check of the denylist refuses it first.
  denylisted("Read", { file_path: "/etc/hosts" }, readable("/etc"));
});

test("#sandbox-readable-folders judges a listed folder, and each path in it, where its symlinks lead", () => {
  // LINK (`~/Documents/link`) leads to `~/.ssh`, so listing it gives nothing.
  assert.deepEqual(readableRoots(HOME, [LINK], linkFs), []);
  // `~/Documents/out` leads to `~/other`, which no store holds and no
  // readable folder holds: the allowlist alone refuses it.
  const outFs = (p: string): string => p.replace(/^\/home\/u\/Documents\/out(?=\/|$)/, "/home/u/other");
  const policy: SandboxPolicy = { ...readable("/home/u/Documents"), realpath: outFs };
  notReadable("Read", { file_path: "/home/u/Documents/out/a.txt" }, policy);
  notReadable("Glob", { path: "/home/u/Documents/out", pattern: "*" }, policy);
  assert.equal(decide("Read", { file_path: "/home/u/Documents/a.txt" }, policy), "allow");
  // A listed symlink that leads to an ordinary folder reads at its target.
  const notesFs = (p: string): string => p.replace(/^\/home\/u\/Notes(?=\/|$)/, "/home/u/Documents/Notes");
  const viaLink: SandboxPolicy = { ...readable("~/Notes"), realpath: notesFs };
  assert.equal(decide("Read", { file_path: "~/Notes/a.md" }, viaLink), "allow");
});

// Advisor is the only source that tells the agent which folders it can read.
// Each refusal of a local path names them, so that the next call goes there.
// Without this, an agent tried twelve other paths and never the notes folder
// that the user listed (2026-11-11).
test("#sandbox-readable-folders each path refusal names the folders that the agent can read", () => {
  const policy = readable("/home/u/Documents", "~/work", "~/Library", "relative", "/home/u/Documents");
  const calls: [string, unknown][] = [
    ["Read", { file_path: "/home/u/notes.txt" }], // in no readable folder
    ["Read", { file_path: "/home/u/.ssh/id_rsa" }], // the denylist
    ["Read", { file_path: "notes.txt" }], // not absolute
    ["Glob", { path: "/home/u", pattern: "*" }], // a search above the stores
    ["Glob", { path: "/home/u/Documents", pattern: "/etc/*" }], // an absolute pattern
    ["Grep", { path: "/home/u/other", pattern: "x" }],
  ];
  for (const [tool, input] of calls) {
    const d = toolDecision(tool, input, policy);
    const message = d.behavior === "deny" ? d.message : "";
    assert.match(message, /: "\/home\/u\/Documents", "\/home\/u\/work"\. /, JSON.stringify(input));
    assert.match(message, /put the folder in `path`/, JSON.stringify(input));
    assert.doesNotMatch(message, /"[^"]*(Library|relative)"/, JSON.stringify(input));
  }
  // The folders that the user lists, but that the policy refuses, are no help.
  const none = toolDecision("Read", { file_path: "/home/u/a.txt" }, readable("~/Library", "/etc"));
  assert.match(none.behavior === "deny" ? none.message : "", /You can read no local file/);
  // A refusal that is not about a local path names no folder.
  for (const [tool, input] of [["Skill", {}], ["mcp__s__delete_file", {}]] as const) {
    const d = toolDecision(tool, input, policy);
    assert.doesNotMatch(d.behavior === "deny" ? d.message : "", /Documents|no local file/, tool);
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

// The session folder is one more readable folder, so the agent must be told
// what it holds, or it does not know to look there (issue #154).
test("#past-sessions the note says which readable folder holds the earlier sessions", () => {
  const sessions = "/home/u/Library/Application Support/Advisor/sessions";
  const said = /"\/home\/u\/Library\/Application Support\/Advisor\/sessions" holds the transcripts of the user's earlier Advisor sessions/;
  const note = readableFoldersNote(HOME, ["/home/u/Documents", sessions], idFs, sessions);
  assert.match(note, /only inside these folders: "\/home\/u\/Documents", "\/home\/u\/Library\/Application Support\/Advisor\/sessions"\. /);
  assert.match(note, said);
  assert.match(note, /yyyy-MM-dd-HHmmss\.md/);
  // In another spelling, it is the same folder.
  assert.match(readableFoldersNote(HOME, [sessions + "/"], idFs, "~/Library/Application Support/Advisor/sessions"), said);
  // Not said for a folder that the agent cannot read now.
  assert.doesNotMatch(readableFoldersNote(HOME, ["/home/u/Documents"], idFs, sessions), /earlier Advisor sessions/);
  assert.doesNotMatch(readableFoldersNote(HOME, ["/home/u/.ssh"], idFs, "/home/u/.ssh"), /earlier Advisor sessions/);
  assert.doesNotMatch(readableFoldersNote(HOME, ["/home/u/Documents"], idFs), /earlier Advisor sessions/);
});
