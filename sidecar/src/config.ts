import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
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
  /// Read/search connector tools are always allowed. (Claude only — Codex MCP
  /// servers come from ~/.codex/config.toml and are not gated here.)
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
  /// Session archive location, mirrored by Preferences.swift. Included in the
  /// effective readable folders so cards can research previous conversations.
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
    sessionDir: str("sessionDir", DEFAULTS.sessionDir),
  };
}

/// Mirror SessionArchive.directory(for:): trim spaces, expand ~, and use the
/// built-in archive for blank or relative paths. The policy still judges this
/// folder, including its symlinks; this is not a sandbox exception.
export function sessionDirectory(value: unknown, home = homedir()): string {
  let folder = typeof value === "string" ? value.replace(/^[\t ]+|[\t ]+$/g, "") : "";
  if (folder === "~") folder = home;
  else if (folder.startsWith("~/")) folder = path.join(home, folder.slice(2));
  return path.isAbsolute(folder) ? folder : path.join(home, "Library/Application Support/Advisor/sessions");
}

/// Effective folders: the user's list plus Advisor's session archive (#154).
/// Read fresh so removing a folder or moving the archive takes effect under
/// the existing Claude/Codex refresh rules. Invalid/unreadable config fails
/// closed; an absent config uses the same default archive as the app.
export function loadReadableFolders(file: string = CONFIG_PATH): string[] {
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ENOENT" ? [sessionDirectory("")] : [];
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return [];
  const config = mergeConfig(raw as Record<string, unknown>);
  return [...new Set([...config.readableFolders, sessionDirectory(config.sessionDir)])];
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
