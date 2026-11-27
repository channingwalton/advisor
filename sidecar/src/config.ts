import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import type { EffortLevel } from "@anthropic-ai/claude-agent-sdk";
import { log } from "./protocol.js";

/// A provider id (registry key in providers.ts). Plain string so new providers
/// need no change here.
export type Provider = string;

export interface AdvisorConfig {
  /// conservative | balanced | eager
  triggerSensitivity: string;
  /// Which trigger kinds are enabled.
  triggers: { question: boolean; context: boolean; factcheck: boolean };
  /// Allow MCP connector tools that take actions (send/create/update/...).
  /// Claude: read/search connector tools are always allowed, and actions only
  /// with this on (`mcpPermission`). Codex has no per-call hook, so a Codex
  /// session gets all the user's connectors with this on and none with it off
  /// (`codexClientOptions`). Advisor's own file tools are not affected.
  allowMcpActions: boolean;
  /// Agent backend shared by every lane (classifier, research, query).
  provider: Provider;
  /// Model id for the provider, or "" = the provider's own default.
  model: string;
  /// How much the card lanes think (an SDK effort level), or "" = inherit the
  /// user's own Claude setting. Not applied to the classifier. Claude only.
  effort: EffortLevel | "";
  /// Write utterance text to the log, not only its length (the app's
  /// "Include transcript text in the log" preference).
  logTranscriptText: boolean;
  /// The folders that the agents may read (absolute, or `~/…`). None by
  /// default: a credential store that the denylist does not name stays out of
  /// reach (GHSA-6xc8-f55f-jxqr). The Claude policy reads it from the file at
  /// each file-tool call, the Claude CLI's Seatbelt profile when the CLI
  /// starts, and the Codex Seatbelt profile before each turn
  /// (`loadReadableFolders`, `refreshCodexSandbox`).
  readableFolders: string[];
  /// The agents may also read the session folder, so a card can draw on the
  /// transcripts of earlier sessions (issue #154). Off by default.
  /// `loadReadableFolders` adds the folder to the list, so every layer of the
  /// sandbox that takes the list takes the folder too.
  readPastSessions: boolean;
  /// The app's session folder setting, as the app reads it
  /// (`SessionArchive.directory(for:)`): "" is the built-in default. The
  /// sidecar reads it only for `readPastSessions` (`sessionFolder`).
  sessionDir: string;
}

const EFFORT_LEVELS: readonly EffortLevel[] = ["low", "medium", "high", "xhigh", "max"];

const DEFAULTS: AdvisorConfig = {
  triggerSensitivity: "balanced",
  triggers: { question: true, context: true, factcheck: true },
  allowMcpActions: false,
  provider: "claude",
  model: "",
  effort: "",
  logTranscriptText: false,
  readableFolders: [],
  readPastSessions: false,
  sessionDir: "",
};

/// The model id to pass to the SDK, or undefined to use the provider's default.
export function modelArg(c: AdvisorConfig): string | undefined {
  return c.model || undefined;
}

/// The effort level to pass to the SDK, or undefined to inherit the user's own.
export function effortArg(c: AdvisorConfig): EffortLevel | undefined {
  return c.effort || undefined;
}

const CONFIG_PATH = `${homedir()}/Library/Application Support/Advisor/config.json`;

/// Merge parsed config over defaults. Missing keys keep their default; unknown
/// keys are ignored. No migration of older shapes — a stale config.json is just
/// partially overridden by its still-recognised keys.
export function mergeConfig(raw: Record<string, unknown>): AdvisorConfig {
  const str = (k: string, d: string): string => (typeof raw[k] === "string" ? (raw[k] as string) : d);
  const bool = (v: unknown, d: boolean): boolean => (typeof v === "boolean" ? v : d);
  // Validate each trigger flag individually: a non-boolean (or an unknown key)
  // must fall back to the default, not leak through and be read as a truthy /
  // falsy boolean downstream. The app's reader (`AdvisorConfig.load`) merges
  // the flags the same way; its decode for a save refuses such a file.
  const rawTriggers = (typeof raw.triggers === "object" && raw.triggers !== null
    ? raw.triggers
    : {}) as Record<string, unknown>;
  return {
    triggerSensitivity: str("triggerSensitivity", DEFAULTS.triggerSensitivity),
    triggers: {
      question: bool(rawTriggers.question, DEFAULTS.triggers.question),
      context: bool(rawTriggers.context, DEFAULTS.triggers.context),
      factcheck: bool(rawTriggers.factcheck, DEFAULTS.triggers.factcheck),
    },
    allowMcpActions: bool(raw.allowMcpActions, DEFAULTS.allowMcpActions),
    provider: str("provider", DEFAULTS.provider),
    model: str("model", DEFAULTS.model),
    // An unknown level (a typo, or one from a newer app) inherits rather than
    // reaching the SDK as an invalid option.
    effort: EFFORT_LEVELS.find((l) => l === raw.effort) ?? DEFAULTS.effort,
    logTranscriptText: bool(raw.logTranscriptText, DEFAULTS.logTranscriptText),
    // Strings only: any other entry, or a value that is not a list, is dropped.
    readableFolders: Array.isArray(raw.readableFolders)
      ? raw.readableFolders.filter((f): f is string => typeof f === "string")
      : [...DEFAULTS.readableFolders],
    readPastSessions: bool(raw.readPastSessions, DEFAULTS.readPastSessions),
    sessionDir: str("sessionDir", DEFAULTS.sessionDir),
  };
}

/// The session folder for a `sessionDir` setting, by the app's rule
/// (`SessionArchive.directory(for:)`), so that the agents read the folder
/// that the app writes: spaces and tabs trimmed, a leading `~` or `~/` is the
/// home folder, and a path that is not absolute gives the built-in default.
/// The app finds another user's home folder for `~name/…`; the sidecar cannot
/// be sure of that folder, so it gives null.
export function sessionFolder(sessionDir: string, home: string): string | null {
  const trimmed = sessionDir.replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, "");
  if (trimmed.startsWith("~") && trimmed !== "~" && !trimmed.startsWith("~/")) return null;
  const expanded = trimmed === "~" ? home : trimmed.startsWith("~/") ? home + trimmed.slice(1) : trimmed;
  return expanded.startsWith("/") ? expanded : `${home}/Library/Application Support/Advisor/sessions`;
}

/// The session folder when the agents may read past sessions, else null.
function pastSessionsFolder(c: AdvisorConfig, home: string): string | null {
  return c.readPastSessions ? sessionFolder(c.sessionDir, home) : null;
}

/// The config file's settings now, or null on any failure.
function readConfigFile(file: string): AdvisorConfig | null {
  try {
    return mergeConfig(JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>);
  } catch {
    return null;
  }
}

/// The readable folders that config.json lists now, and the session folder
/// while `readPastSessions` is on (issue #154). Each Read, Grep and Glob call
/// reads them, so a folder that the user removes is refused at once, not at
/// the next session (code review 2026-11-10). Any failure gives none.
export function loadReadableFolders(file: string = CONFIG_PATH, home: string = homedir()): string[] {
  const c = readConfigFile(file);
  if (c === null) return [];
  const sessions = pastSessionsFolder(c, home);
  return sessions === null ? c.readableFolders : [...c.readableFolders, sessions];
}

/// The session folder that `loadReadableFolders` adds now, or null: the task
/// note tells the agent what the folder holds (`readableFoldersNote`).
export function loadPastSessionsFolder(file: string = CONFIG_PATH, home: string = homedir()): string | null {
  const c = readConfigFile(file);
  return c === null ? null : pastSessionsFolder(c, home);
}

export function loadConfig(): AdvisorConfig {
  try {
    const raw = JSON.parse(readFileSync(CONFIG_PATH, "utf8")) as Record<string, unknown>;
    return mergeConfig(raw);
  } catch {
    log("no config.json, using defaults");
    return mergeConfig({});
  }
}
