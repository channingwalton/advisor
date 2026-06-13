import { readFileSync } from "node:fs";
import { homedir } from "node:os";
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
}

const DEFAULTS: AdvisorConfig = {
  triggerSensitivity: "balanced",
  triggers: { question: true, context: true, factcheck: true },
  allowMcpActions: false,
  provider: "claude",
  model: "",
};

/// The model id to pass to the SDK, or undefined to use the provider's default.
export function modelArg(c: AdvisorConfig): string | undefined {
  return c.model || undefined;
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
  // falsy boolean downstream. Matches the Swift side's strict decode.
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
  };
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
