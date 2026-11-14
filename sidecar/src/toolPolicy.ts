import fs from "node:fs";
import path from "node:path";

/// The sandbox policy for the agents' local reads (GHSA-6xc8-f55f-jxqr): which
/// paths Read, Grep and Glob may reach, which connector tools may run, and the
/// note that tells an agent its readable folders. Both Seatbelt profiles take
/// their read rules from it (`seatbelt.ts`). It loads only Node's own modules,
/// so a process can apply it without the agent SDKs.

/// Paths (relative to $HOME) the agents may never read, even inside $HOME.
/// A denylist fails open for a store that it does not name, so the Claude
/// policy reads only the readable folders (`readableRoots`), and this list
/// refuses a readable folder at, under or above a store. The Codex Seatbelt
/// profile uses the same list (minus Codex's own state), so a Codex connector
/// cannot read these either.
const DENY_NAMES = [
  ".ssh",
  ".aws",
  ".gnupg",
  ".claude",
  ".claude.json",
  ".npmrc",
  ".netrc",
  ".git-credentials",
  ".docker",
  ".kube",
  ".codex", // Codex provider creds/config (auth.json, config.toml)
  ".codex-global-state.json", // Codex global state (tokens)
  ".config/gh",
  "Library/Keychains",
  "Library/Cookies",
  // GHSA-6xc8-f55f-jxqr. Shell and REPL history: commands with inline secrets.
  ".zsh_history", ".zhistory", ".zsh_sessions", ".bash_history", ".bash_sessions", ".history",
  ".local/share/fish", ".python_history", ".node_repl_history", ".psql_history",
  ".mysql_history", ".sqlite_history",
  // Cloud, deploy and password-manager credentials.
  ".config/gcloud", ".azure", ".oci", ".boto", ".s3cfg", ".terraform.d", ".terraformrc",
  ".vault-token", ".config/doctl", ".config/op", ".password-store", ".config/git/credentials",
  ".config/github-copilot",
  // Package-registry and database credentials.
  ".pypirc", ".pgpass", ".cargo/credentials", ".cargo/credentials.toml", ".gem/credentials",
  ".m2/settings.xml", ".ivy2/.credentials", ".sbt/.credentials", ".gradle/gradle.properties",
  ".yarnrc", ".yarnrc.yml", ".config/hub", ".config/glab-cli",
  // Other MCP clients' configuration, which holds server tokens.
  ".cursor", ".codeium", ".config/zed", "Library/Application Support/Claude",
  // Browser profiles: saved passwords, cookies, history.
  "Library/Application Support/Google", "Library/Application Support/Chromium",
  "Library/Application Support/Firefox",
  "Library/Application Support/BraveSoftware", "Library/Application Support/Microsoft Edge",
  "Library/Application Support/Arc", "Library/Application Support/Vivaldi",
  "Library/Application Support/com.operasoftware.Opera", "Library/Safari",
  // Electron and Chromium apps: session cookies and tokens.
  "Library/Application Support/Slack", "Library/Application Support/discord",
  "Library/Application Support/Code", "Library/Application Support/Cursor",
];

export function deniedPaths(home: string): string[] {
  return DENY_NAMES.map((p) => path.join(home, p));
}

/// Resolve a tool path argument to an absolute root. undefined/null/"" means the
/// tool defaults to cwd; a non-string is invalid (null). Not normalised: see
/// `canonical`.
function resolveRoot(cwd: string, p: unknown): string | null {
  if (p === undefined || p === null || p === "") return cwd;
  if (typeof p !== "string") return null;
  return path.isAbsolute(p) ? p : `${cwd}/${p}`;
}

/// macOS's default filesystem is case-insensitive, so `~/.SSH/id_rsa` reaches
/// the same file as `~/.ssh/id_rsa`. Compare case-folded so a case variant can
/// never slip past the denylist. (Strictly safer than the FS: on a genuinely
/// case-sensitive volume this only ever denies more, never less.)
function isUnder(child: string, parent: string): boolean {
  const c = child.toLowerCase();
  const p = parent.toLowerCase();
  return c === p || c.startsWith(p + path.sep);
}

/// `isUnder` without the case fold, for an allow: on a case-sensitive volume,
/// `~/public` is not the listed `~/Public`. Compare resolved paths, which
/// hold the stored names, so a case variant on the default volume still
/// matches (code review 2026-11-10).
function isUnderExact(child: string, parent: string): boolean {
  return child === parent || child.startsWith(parent + path.sep);
}

/// realpath(3): the path as the filesystem stores it. Node's JS `realpathSync`
/// resolves symlinks but keeps each name as given, and APFS folds more than
/// ASCII case: `.ſsh` (long s), `.ßh` and `.conﬁg` (fi ligature) open `.ssh`
/// and `.config`. The lower-cased compare of the given spelling passed them
/// (GHSA-6xc8-f55f-jxqr). The native call returns the stored names, so
/// `isUnder` compares what the filesystem will open.
export const REALPATH = (p: string): string => fs.realpathSync.native(p);

/// Resolve symlinks so the denylist sees the real target, not a link that
/// points into a denied dir (e.g. ~/Documents/x -> ~/.ssh). A purely lexical
/// check is bypassable by one symlink. realpathSync needs the path to exist, so
/// for a not-yet-existing leaf we resolve the deepest existing ancestor and
/// re-append the unresolved tail (which, not existing, can hold no symlinks).
function realResolve(abs: string, realpath: (p: string) => string): string {
  const tail: string[] = [];
  let cur = abs;
  for (;;) {
    try {
      return path.join(realpath(cur), ...[...tail].reverse());
    } catch {
      const parent = path.dirname(cur);
      if (parent === cur) return abs; // reached root with nothing resolvable
      tail.push(path.basename(cur));
      cur = parent;
    }
  }
}

/// `abs` resolved by the filesystem, then normalised.
function canonical(abs: string, realpath: (p: string) => string): string {
  return path.resolve(realResolve(abs, realpath));
}

/// The paths that the policy judges for `abs`, which a `..` can make two. The
/// kernel follows a symlink before it applies a later `..`, so with `k ->
/// ~/.ssh/keys`, `~/Documents/k/../id` opens `~/.ssh/id`. A caller that
/// normalises first (the CLI does, for Read) applies the `..` first, so with
/// `deep -> ~/work/sub`, `~/deep/../.ssh/id` opens `~/.ssh/id`. A Grep or
/// Glob `path` reaches the gate unexpanded, and a later CLI may stop
/// normalising, so both forms are judged (code review 2026-11-10).
function judgedForms(abs: string, realpath: (p: string) => string): string[] {
  return [...new Set([canonical(abs, realpath), canonical(path.resolve(abs), realpath)])];
}

/// Read policy: any non-sensitive file at or under $HOME; nothing outside.
/// Keep both lexical and resolved denied roots: a credential directory may
/// itself be a symlink (e.g. ~/.ssh -> ~/dotfiles/.ssh).
/// `realpath` is injectable for tests; production uses the real filesystem.
export function readPathAllowed(
  home: string,
  cwd: string,
  p: unknown,
  realpath: (p: string) => string = REALPATH
): boolean {
  const r0 = resolveRoot(cwd, p);
  if (r0 === null) return false;
  const forms = judgedForms(r0, realpath);
  // A form holds the stored form of each name, which can differ from $HOME's
  // (NFD and NFC spellings of an accented name), so compare with both.
  const homes = [home, canonical(home, realpath)];
  if (!forms.every((r) => homes.some((h) => isUnder(r, h)))) return false;
  const roots = deniedRoots(home, realpath);
  return !forms.some((r) => roots.some((d) => isUnder(r, d)));
}

/// Each denied path, lexical and resolved.
function deniedRoots(home: string, realpath: (p: string) => string): string[] {
  return [...new Set(deniedPaths(home).flatMap((d) => [d, canonical(d, realpath)]))];
}

/// The readable folders that the policy honours (GHSA-6xc8-f55f-jxqr): Read,
/// Grep and Glob reach only paths inside one. The user lists them in
/// Preferences → Files (`readableFolders` in config.json), and the default is
/// none, so an agent reads no local file until the user lists a folder. A
/// folder is refused when it is not in the home folder, or when it is at,
/// under or above a denied path, in its listed or its resolved form: `~`,
/// `~/Library` and a symlink into `~/.ssh` give nothing, while
/// `~/Library/Mobile Documents` is honoured. An entry that is not absolute
/// after `~` expansion is ignored. Each honoured folder is returned in its
/// listed and its resolved forms.
export function readableRoots(
  home: string,
  folders: readonly string[],
  realpath: (p: string) => string = REALPATH
): string[] {
  return [...new Set(honouredFolders(home, folders, realpath).flatMap((h) => h.forms))];
}

/// Each listed folder that the policy honours (`readableRoots`): its absolute
/// path, and its forms.
export function honouredFolders(
  home: string,
  folders: readonly string[],
  realpath: (p: string) => string
): { folder: string; forms: string[] }[] {
  const homes = [home, canonical(home, realpath)];
  const denied = deniedRoots(home, realpath);
  return folders.flatMap((listed) => {
    const abs = absolutePath(listed, home);
    if (abs === null) return [];
    const folder = path.resolve(abs);
    const forms = [...new Set([folder, ...judgedForms(abs, realpath)])];
    const inHome = forms.every((f) => homes.some((h) => isUnder(f, h)));
    const clash = forms.some((f) => denied.some((d) => isUnder(f, d) || isUnder(d, f)));
    return inHome && !clash ? [{ folder, forms }] : [];
  });
}

/// The folders that the agent can read, as one sentence. Advisor is the only
/// source of this list for the agent, so each run of a session that reads
/// files starts with it, and each refusal of a local path ends with it.
/// Without it, an agent tried twelve other paths and never the notes folder
/// that the user listed (2026-11-11). Each folder is in quotes, because a
/// folder name can hold a comma. The note also says how to call Glob: with
/// a notes folder in `path`, the CLI's Glob found nothing for a pattern that
/// started with folder names (`A/B/*.md`), with or without the Seatbelt
/// profile, while `*.md` with `A/B` in `path` found its 12 notes. An agent
/// then decided that the notes did not exist, and searched for a minute
/// (2026-11-12).
export function readableFoldersNote(
  home: string,
  folders: readonly string[],
  realpath: (p: string) => string = REALPATH
): string {
  const honoured = [...new Set(honouredFolders(home, folders, realpath).map((h) => h.folder))];
  return honoured.length > 0
    ? `Advisor lets you read local files only inside these folders: ${honoured.map((f) => JSON.stringify(f)).join(", ")}. ` +
      "To find files with Glob, put the folder in `path`, and start the pattern with `*` or `**`, such as `**/*.md`: " +
      "a pattern that starts with a folder name can find nothing."
    : `You can read no local file: Advisor's Preferences (Files) list no folder that Advisor lets you read.`;
}

/// Each form of `abs` is in a readable root.
function inReadableRoot(roots: readonly string[], abs: string, realpath: (p: string) => string): boolean {
  return judgedForms(abs, realpath).every((r) => roots.some((f) => isUnderExact(r, f)));
}

/// Search (Grep/Glob) policy: stricter than Read because these recurse — a
/// recursive pattern from an allowed root would otherwise reach secrets in a
/// denied descendant (e.g. Glob {path:$HOME, pattern:".ssh/**"} or
/// Grep {path:$HOME, pattern:"PRIVATE KEY"}). So validating the root path is not
/// enough: the root must also not sit at or above any denied path. This makes an
/// unscoped $HOME-rooted search illegal; agents must target a specific subtree.
export function searchRootAllowed(
  home: string,
  cwd: string,
  p: unknown,
  realpath: (p: string) => string = REALPATH
): boolean {
  if (!readPathAllowed(home, cwd, p, realpath)) return false;
  const roots = deniedRoots(home, realpath);
  return !judgedForms(resolveRoot(cwd, p)!, realpath).some((r) => roots.some((d) => isUnder(d, r)));
}

/// Connector action verbs — tools that can change external state — wherever
/// they sit in the tool name. Names reach the patterns normalised
/// (`normaliseVerbName`): lower-case words joined by `_`, so `_`/end are the
/// word boundaries and `set` never trips on `settings`/`assets`. Checked BEFORE
/// the read allowlist so a name carrying both an action and a read verb
/// (`ddsql_upsert_saved_query`, `searchAndUpdate`) is gated.
const MCP_ACTION_PATTERN =
  /(?:^|_)(send|post|create|update|upsert|delete|remove|write|upload|install|uninstall|add|run|exec|execute|start|stop|enable|disable|schedule|transition|invite|archive|publish|edit|move|rename|merge|close|cancel|assign|apply|approve|reject|import|export|reset|clear|drop|grant|revoke|set|authenticate|complete|replace|insert|append|submit|save|modify|put|purge|trash|wipe|sync|notify|acknowledge|trigger|subscribe|unsubscribe|restore|lock|unlock|toggle|pay|transfer|kill|terminate|destroy|revert|rotate|register|unregister|dismiss|escalate|refresh|regenerate|redeem|snooze|forward|convert|generate|compose|ban|mute|block|accept|decline|unfollow|migrate|truncate|flush|invalidate|rewrite|overwrite|undelete|prepend)(?:_|$)/;

/// Verbs that are also the nouns read tools are named after (`get_comment`,
/// `list_deploy_keys`, `get_share_link`, `get_open_issues`, `get_commit_patch`):
/// an action unless a read verb comes before them in the name — so
/// `comment_on_issue`, `share_file`, `mark_read` and the service-prefixed
/// `gmail_mark_as_read` are actions, `jira_get_issue_comment` is a read. Code
/// review 2026-10-17 — `share` had sat in the read list, and sharing grants a
/// third party access.
const MCP_AMBIGUOUS_ACTION_PATTERN =
  /(?:^|_)(comment|reply|mark|share|copy|duplicate|push|deploy|patch|open|commit|release|flag|star|pin|react|follow|resolve|checkout|draft|like|vote|tag)(?:_|$)/;

/// `x_and_y` does y, whatever x says: a conjunction denies the name outright,
/// so an action verb the lists above lack cannot ride in behind a read verb
/// (`find_and_replace`, `get_or_insert`, `fetch_and_purge`). Fail-closed, so a
/// read tool named with one (`search_public_and_private`) is refused too — the
/// recorded cost.
const MCP_CONJUNCTION_PATTERN = /_(and|or|then)_/;

/// Connector read/search verbs, anywhere in the name — connectors prefix their
/// tools with the service or entity (`slack_search_public`, `ddsql_query`).
/// Whole words (`listen` is not `list`). A verb on neither action list ahead of
/// one of these passes; the lists above are the defence against that, and
/// connector actions being off by default the backstop.
const MCP_READ_PATTERN =
  /(?:^|_)(get|list|search|read|fetch|lookup|view|find|describe|query|aggregate|analy[sz]e|explore|expand|rank|recommend|summari[sz]e|visuali[sz]e|typecheck|diff|shared)(?:_|$)/;

/// Nouns a tool is named after when it returns them: a read as the whole name
/// (`docs`) or its last word (`conversations_history`, `atlassian_user_info`,
/// `table_schema`, `schema_info`), so `purge_history`, `sync_schema` and
/// `schema_migrate` are judged by their verb, not waved through on the noun.
const MCP_READ_NOUN_PATTERN = /(?:^|_)(history|docs?|info|schema)$/;

/// The bare tool name after the `mcp__<server>__` prefix (so the server name
/// can't trip a verb match). The prefix ends at the first `__` after the server
/// name — a tool's own name may contain `__` too (`delete__list`), and taking
/// the last one would judge it on its final word alone. Non-MCP names are
/// returned unchanged.
export function bareMcpName(toolName: string): string {
  const m = /^mcp__.+?__(.*)$/.exec(toolName);
  return m ? m[1] : toolName;
}

/// Lower-case words joined by `_`, so the verb patterns' `^ / _` word anchors
/// see every word. camelCase splits (`fetchAndDelete` → `fetch_and_delete`:
/// without this, `delete` hides behind a lower-case letter and dodges the
/// case-sensitive match, so the action gate misses it and the leading `fetch`
/// waves it through — a fail-OPEN), an acronym run splits before its last
/// capital (`getHTTPPutURL` → `get_http_put_url`), and every other separator a
/// tool name may use (`-`, `.`, `/`, `:`, space) becomes `_`
/// (`search.delete` → `search_delete`), since a verb after one of those was
/// invisible to anchors that knew only `_` and `-`.
export function normaliseVerbName(name: string): string {
  return name
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_");
}

/// MCP connector permission. Fail closed: when actions are disabled a tool is
/// allowed only if it is recognised as a read/search. An action verb, a
/// conjunction, OR any name we don't recognise, is denied — a new mutating tool
/// we've never seen is blocked by default rather than waved through.
export function mcpPermission(toolName: string, allowMcpActions: boolean): "allow" | "deny" {
  if (allowMcpActions) return "allow";
  const name = normaliseVerbName(bareMcpName(toolName));
  if (MCP_CONJUNCTION_PATTERN.test(name)) return "deny";
  if (MCP_ACTION_PATTERN.test(name)) return "deny";
  const read = MCP_READ_PATTERN.exec(name);
  const ambiguous = MCP_AMBIGUOUS_ACTION_PATTERN.exec(name);
  if (ambiguous && (!read || ambiguous.index < read.index)) return "deny";
  if (read) return "allow";
  if (MCP_READ_NOUN_PATTERN.test(name)) return "allow";
  return "deny";
}

/// Tools that need no path check. Everything else the CLI offers that isn't
/// Read/Grep/Glob or an MCP connector tool — Skill, Task*/Team*/Workflow, Cron*,
/// AskUserQuestion, worktrees, … — is refused. ToolSearch stays: it is how the CLI
/// loads deferred connector tools, so refusing it would cut agents off from MCP.
const OPEN_TOOLS = new Set([
  "WebSearch", "WebFetch", "ToolSearch",
  // SDK MCP resource enumeration/read — pure reads. (Both the bare and
  // `…Tool`-suffixed names the SDK may use.)
  "ListMcpResources", "ReadMcpResource", "ListMcpResourcesTool", "ReadMcpResourceTool",
]);

export interface SandboxPolicy {
  home: string;
  /// The CLI's working directory.
  cwd: string;
  allowMcpActions: boolean;
  /// The folders that the user lists as readable (`readableRoots`).
  readableFolders: readonly string[];
  /// Injectable for tests; production resolves symlinks on the real filesystem.
  realpath?: (p: string) => string;
}

export type ToolDecision = { behavior: "allow" } | { behavior: "deny"; message: string };

/// A path argument as the CLI will open it, or null when the policy can't be sure
/// which file that is. A leading `~` is the home directory, as the CLI expands it
/// (Read's before the gate; Glob/Grep's `path` reaches the gate unexpanded). A
/// relative path resolves against the CLI's cwd, so it is refused and the agent
/// retries with an absolute one. Advisor's own file tools open this path, so
/// they open the path that the policy judged (`localFiles.ts`).
export function absolutePath(p: unknown, home: string): string | null {
  if (typeof p !== "string") return null;
  const expanded = p === "~" ? home : p.startsWith("~/") ? home + p.slice(1) : p;
  return path.isAbsolute(expanded) ? expanded : null;
}

/// A Glob pattern (or Grep `glob` filter) that stays inside the root the policy
/// checked. The CLI searches an absolute pattern's own base directory instead of
/// `path`, so a permitted `path` with pattern `~/.ssh/*` listed the denied
/// directory (code review 2026-10-06). Refuse a pattern, or any brace
/// alternative of it (`{a, /etc/*}`), that starts with `/` or `~`, and any `..`
/// — the folder belongs in `path`. A `~` inside a name is literal (`*~`). Grep's
/// `glob` is optional (undefined passes).
function patternStaysInRoot(p: unknown): boolean {
  if (p === undefined) return true;
  if (typeof p !== "string") return false;
  return !(/(^|[{,])\s*[/~]/.test(p) || p.includes(".."));
}

/// The sandbox policy for one tool call. Shared by the PreToolUse gate and
/// canUseTool so the two can never disagree.
export function toolDecision(toolName: string, input: unknown, policy: SandboxPolicy): ToolDecision {
  const allow: ToolDecision = { behavior: "allow" };
  if (OPEN_TOOLS.has(toolName)) return allow;
  // User-configured MCP connectors (Slack, Jira, ...): reads/searches allowed;
  // action tools only when enabled in preferences. Fail closed (mcpPermission).
  if (toolName.startsWith("mcp__")) {
    return mcpPermission(toolName, policy.allowMcpActions) === "allow" ? allow : {
      behavior: "deny",
      message:
        `${toolName} is not an allowed read/search connector tool. ` +
        `Advisor allows read/search connector tools only, unless "Allow connector actions" is enabled in Preferences.`,
    };
  }
  const args = (input !== null && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const { home, cwd, realpath = REALPATH } = policy;
  // A refusal of a local path names the folders that the agent can read
  // (`readableFoldersNote`). `readableFolders` reads the file, so only once.
  const refused = (message: string, folders = policy.readableFolders): ToolDecision => ({
    behavior: "deny",
    message: `${message} ${readableFoldersNote(home, folders, realpath)}`,
  });
  // The denylist first: its refusal names the real reason for a store that
  // is also outside every readable folder.
  const decide = (abs: string | null, permitted: typeof readPathAllowed): ToolDecision => {
    if (abs === null || !permitted(home, cwd, abs, realpath)) {
      return refused(`Access denied: ${toolName} needs an absolute path to a non-sensitive file or folder in the home directory.`);
    }
    const folders = policy.readableFolders;
    if (inReadableRoot(readableRoots(home, folders, realpath), abs, realpath)) return allow;
    return refused(
      `Access denied: ${toolName} reads only inside the folders that the user lists as readable ` +
        `in Advisor's Preferences (Files), and this path is in none of them.`,
      folders
    );
  };
  switch (toolName) {
    case "Read":
      return decide(absolutePath(args.file_path, home), readPathAllowed);
    case "Grep":
    case "Glob": {
      if (!patternStaysInRoot(toolName === "Glob" ? args.pattern : args.glob)) {
        return refused(
          `Access denied: ${toolName} patterns must be relative — no absolute, ~ or .. patterns. Put the folder in \`path\`.`
        );
      }
      return decide(absolutePath(args.path, home), searchRootAllowed);
    }
    default:
      return { behavior: "deny", message: `${toolName} is not permitted in Advisor` };
  }
}
