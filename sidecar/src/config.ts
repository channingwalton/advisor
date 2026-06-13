import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { log } from "./protocol.js";
import { DEFAULT_PERSONA } from "./prompts.js";

/// A provider id (registry key in providers.ts). Plain string so new providers
/// need no change here.
export type Provider = string;

export interface AdvisorConfig {
  /// Editable persona/style block at the head of the research agents' system
  /// prompt. The protected operational core lives in prompts.ts, not here.
  personaPrompt: string;
  /// Appended to the research agents' system prompt.
  extraInstructions: string;
  /// conservative | balanced | eager
  triggerSensitivity: string;
  /// Which trigger kinds are enabled.
  triggers: { question: boolean; context: boolean; factcheck: boolean };
  maxTriggersPerPass: number;
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
  personaPrompt: DEFAULT_PERSONA,
  extraInstructions: "",
  triggerSensitivity: "balanced",
  triggers: { question: true, context: true, factcheck: true },
  maxTriggersPerPass: 2,
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
  const num = (k: string, d: number): number => (typeof raw[k] === "number" ? (raw[k] as number) : d);
  const bool = (k: string, d: boolean): boolean => (typeof raw[k] === "boolean" ? (raw[k] as boolean) : d);
  return {
    personaPrompt: str("personaPrompt", DEFAULTS.personaPrompt),
    extraInstructions: str("extraInstructions", DEFAULTS.extraInstructions),
    triggerSensitivity: str("triggerSensitivity", DEFAULTS.triggerSensitivity),
    triggers: { ...DEFAULTS.triggers, ...((raw.triggers as object) ?? {}) },
    maxTriggersPerPass: num("maxTriggersPerPass", DEFAULTS.maxTriggersPerPass),
    allowMcpActions: bool("allowMcpActions", DEFAULTS.allowMcpActions),
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
