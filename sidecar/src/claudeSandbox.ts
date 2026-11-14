import { spawn } from "node:child_process";
import path from "node:path";
import type { SpawnedProcess, SpawnOptions } from "@anthropic-ai/claude-agent-sdk";
import {
  escapeRegex, homeReadRules, nativeOrSelf, realpathLeaf, realpathOrSelf, seatbeltProfile, storeDenials, TEMP_ROOTS,
  writableTemps, type SeatbeltPolicy,
} from "./seatbelt.js";

/// What the Claude profile lets the CLI read and write in the home folder
/// (GHSA-6xc8-f55f-jxqr).
export interface ClaudeReads {
  /// The folders that the user lists as readable, as config.json holds them.
  folders: readonly string[];
  /// The folder that holds the native `claude` binary.
  cliRoot: string;
  /// The CLI's working folder.
  cwd: string;
  /// The subscription login is in the login keychain, which the CLI reads,
  /// and writes when it refreshes the login. With an API key the CLI does not
  /// need it, so the keychain stays refused (decided 2026-11-11).
  keychain: boolean;
  /// `CLAUDE_CONFIG_DIR`, when it is set and is not `~/.claude`.
  configDir?: string;
}

/// The CLI's own files in the home folder: its settings, sessions, plugins
/// and the user's `CLAUDE.md` (`~/.claude`), and its main config with the MCP
/// servers (`~/.claude.json` and the backup and lock that the CLI keeps beside
/// it). The tool gate still refuses the agent's own reads of them
/// (`toolDecision`); the CLI and its connectors can read them, as Codex can
/// read `~/.codex`.
const CLAUDE_STATE = [".claude", ".claude.json", ".claude.json.backup", ".claude.json.lock"];

/// The keychain that holds the subscription login. The CLI reads and writes
/// its login through `security`, which needs only this file, the metadata of
/// its folder, its temp files and the lock files, so the other keychains stay
/// refused (decided 2026-11-11).
const LOGIN_KEYCHAIN = "Library/Keychains/login.keychain-db";

/// The lock files that `security` keeps beside each keychain: `.fl` and a hash
/// of the file name. They are empty, and a write must read its lock file:
/// without them, the CLI could not save a refreshed login (verified
/// 2026-11-11).
const KEYCHAIN_LOCK = "/\\.fl[0-9A-Fa-f]+$";

/// `security` saves a keychain as a temp file beside it (the keychain's name,
/// a dot and a suffix), which it renames over the keychain. Without them a
/// save failed with exit 161 (verified 2026-11-14).
const KEYCHAIN_TEMP = "\\.";

/// The CLI names a project's folder after its resolved working folder, each
/// character other than a letter or a digit as `-`. A longer name than this
/// gets a hash that Advisor does not compute (CLI 2.1.173).
const PROJECT_NAME_MAX = 200;

/// The CLI's own folders that it may write: the transcripts of its sessions in
/// `cwd` (`<config folder>/projects/<name>`), and its connectors' logs
/// (`~/Library/Caches/claude-cli-nodejs/<name>`). The user allows these and no
/// other writes in the home folder (decided 2026-11-14). The CLI cannot create
/// them under the profile, so the session creates them before it starts the
/// CLI. None for a working folder whose name the CLI would hash, and none for
/// a `configDir` that is not absolute, such as a `~/…` that no shell expanded:
/// the session would create it under its own working folder (code review
/// 2026-11-14). The CLI then keeps no transcript.
export function claudeWriteFolders(home: string, cwd: string, configDir?: string): string[] {
  const name = realpathOrSelf(cwd).replace(/[^a-zA-Z0-9]/g, "-");
  if (name.length > PROJECT_NAME_MAX || (configDir !== undefined && !path.isAbsolute(configDir))) return [];
  return [
    path.join(configDir ?? path.join(home, ".claude"), "projects", name),
    path.join(home, "Library", "Caches", "claude-cli-nodejs", name),
  ];
}

/// The Seatbelt policy for one Claude CLI: the home folder is refused, except
/// the readable folders, the CLI's folder, its working folder, a `TMPDIR` in
/// the home folder, a `CLAUDE_CONFIG_DIR` and the CLI's write folders (each
/// judged as a listed folder is), and the CLI's own state, with the login
/// keychain in subscription mode. The stores stay refused last. The CLI's
/// children, the user's stdio connectors among them, inherit it, so a
/// connector's path argument cannot reach a file outside the readable folders
/// (fault 2 of GHSA-6xc8-f55f-jxqr).
///
/// Writes are confined to the temp folders `tmps`, `/dev`, the CLI's write
/// folders (`claudeWriteFolders`), and in subscription mode the login
/// keychain with its temp and lock files. With writes open, a process could
/// move a store into a readable folder and read it there (code review
/// 2026-11-14). The user decided that the CLI reads, and writes only its
/// transcripts and logs (decided 2026-11-14).
export function claudeSandboxPolicy(home: string, reads: ClaudeReads, tmps: readonly string[] = TEMP_ROOTS): SeatbeltPolicy {
  const state = [...CLAUDE_STATE, ...(reads.keychain ? [LOGIN_KEYCHAIN] : [])].map((p) => path.join(home, p));
  const own = claudeWriteFolders(home, reads.cwd, reads.configDir);
  const judged = [...reads.folders, reads.cliRoot, reads.cwd, ...tmps, ...own, ...(reads.configDir ? [reads.configDir] : [])];
  // The keychain folder is a store. Refused last, it would also refuse the
  // login keychain in it. The home-folder denial still refuses the rest of it.
  const keychains = path.join(home, "Library", "Keychains");
  const kept = reads.keychain ? [...state, keychains] : state;
  const keychainForms = [...new Set([keychains, realpathLeaf(keychains), nativeOrSelf(keychains)])];
  const login = (k: string): string => `^${escapeRegex(path.join(k, path.basename(LOGIN_KEYCHAIN)))}${KEYCHAIN_TEMP}`;
  const lock = (k: string): string => `^${escapeRegex(k)}${KEYCHAIN_LOCK}`;
  const writable = [...writableTemps(home, tmps), "/dev", ...own, ...(reads.keychain ? [path.join(home, LOGIN_KEYCHAIN)] : [])];
  return {
    ...homeReadRules(home, judged, state),
    readPatterns: reads.keychain ? keychainForms.map(lock) : [],
    readDenials: storeDenials(home, kept),
    confineWrites: true,
    writableRoots: [...new Set(writable.map(realpathLeaf))],
    writePatterns: reads.keychain ? keychainForms.flatMap((k) => [login(k), lock(k)]) : [],
    writeDenials: [],
  };
}

/// The profile text for one Claude CLI (`claudeSandboxPolicy`).
export function claudeSandboxProfile(home: string, reads: ClaudeReads, tmps?: readonly string[]): string {
  return seatbeltProfile(claudeSandboxPolicy(home, reads, tmps));
}

/// Start the CLI as the SDK would (`spawnLocalProcess`), but under `profile`.
/// The profile goes inline (`sandbox-exec -p`), so each CLI has the policy of
/// its own start and no file is shared between sessions. The SDK cannot reach
/// the stderr of a process that this hook starts, so `onStderr` gets it, as
/// the SDK's `stderr` option would: a CLI that cannot start, or a profile that
/// does not compile, then shows its reason in the log (code review 2026-11-11).
export function spawnClaudeSandboxed(
  o: SpawnOptions,
  profile: string,
  onStderr: (data: string) => void
): SpawnedProcess {
  const child = spawn("/usr/bin/sandbox-exec", ["-p", profile, o.command, ...o.args], {
    cwd: o.cwd,
    env: o.env,
    signal: o.signal,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  child.stderr.on("data", (data: Buffer) => onStderr(data.toString()));
  return {
    stdin: child.stdin,
    stdout: child.stdout,
    get killed() {
      return child.killed;
    },
    get exitCode() {
      return child.exitCode;
    },
    kill: child.kill.bind(child),
    on: child.on.bind(child),
    once: child.once.bind(child),
    off: child.off.bind(child),
  };
}
