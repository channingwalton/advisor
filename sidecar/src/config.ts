import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { log } from "./protocol.js";
import { DEFAULT_PERSONA } from "./prompts.js";

/// A provider id (registry key in providers.ts). Plain string so new providers
/// need no change here.
export type Provider = string;

/// Per-component provider choice. Each component (classifier, research, query)
/// picks a provider and remembers a model id per provider, so switching
/// provider restores the previously-chosen model. Absent/"" = that provider's
/// default.
export interface ProviderChoice {
  provider: Provider;
  models: Record<string, string>;
}

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
  /// Trigger classifier backend.
  classifier: ProviderChoice;
  /// Auto-trigger research lanes backend.
  research: ProviderChoice;
  /// Manual query / right-click action lane backend.
  queryAgent: ProviderChoice;
}

const DEFAULTS: AdvisorConfig = {
  personaPrompt: DEFAULT_PERSONA,
  extraInstructions: "",
  triggerSensitivity: "balanced",
  triggers: { question: true, context: true, factcheck: true },
  maxTriggersPerPass: 2,
  allowMcpActions: false,
  classifier: { provider: "claude", models: { claude: "haiku" } },
  research: { provider: "claude", models: {} },
  queryAgent: { provider: "claude", models: {} },
};

/// Resolve the model id to pass to the SDK for a component, or undefined to use
/// the provider's own default.
export function modelFor(c: ProviderChoice): string | undefined {
  return c.models[c.provider] || undefined;
}

/// Normalise any historical choice shape to {provider, models}:
///   v3 {provider, models}             — current
///   v2 {provider, claudeModel, codexModel}
///   v1 a legacy flat model string (classifierModel/researchModel)
export function toChoice(
  v: unknown,
  legacyFlat: string | undefined,
  def: ProviderChoice
): ProviderChoice {
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    const provider = typeof o.provider === "string" ? o.provider : def.provider;
    if (o.models && typeof o.models === "object") {
      return { provider, models: { ...(o.models as Record<string, string>) } };
    }
    const models: Record<string, string> = {};
    for (const [field, prov] of [["claudeModel", "claude"], ["codexModel", "codex"]] as const) {
      if (typeof o[field] === "string" && o[field]) models[prov] = o[field] as string;
    }
    return { provider, models };
  }
  if (typeof legacyFlat === "string" && legacyFlat) {
    return { provider: "claude", models: { claude: legacyFlat } };
  }
  return { provider: def.provider, models: { ...def.models } };
}

const CONFIG_PATH = `${homedir()}/Library/Application Support/Advisor/config.json`;

/// Merge parsed config over defaults, normalising each provider choice.
export function mergeConfig(raw: Record<string, unknown>): AdvisorConfig {
  const str = (k: string, d: string): string => (typeof raw[k] === "string" ? (raw[k] as string) : d);
  const num = (k: string, d: number): number => (typeof raw[k] === "number" ? (raw[k] as number) : d);
  const bool = (k: string, d: boolean): boolean => (typeof raw[k] === "boolean" ? (raw[k] as boolean) : d);
  const researchLegacy = typeof raw.researchModel === "string" ? (raw.researchModel as string) : undefined;
  const classifierLegacy = typeof raw.classifierModel === "string" ? (raw.classifierModel as string) : undefined;
  return {
    personaPrompt: str("personaPrompt", DEFAULTS.personaPrompt),
    extraInstructions: str("extraInstructions", DEFAULTS.extraInstructions),
    triggerSensitivity: str("triggerSensitivity", DEFAULTS.triggerSensitivity),
    triggers: { ...DEFAULTS.triggers, ...((raw.triggers as object) ?? {}) },
    maxTriggersPerPass: num("maxTriggersPerPass", DEFAULTS.maxTriggersPerPass),
    allowMcpActions: bool("allowMcpActions", DEFAULTS.allowMcpActions),
    classifier: toChoice(raw.classifier, classifierLegacy, DEFAULTS.classifier),
    research: toChoice(raw.research, researchLegacy, DEFAULTS.research),
    // queryAgent historically shared the research model (v1).
    queryAgent: toChoice(raw.queryAgent, researchLegacy, DEFAULTS.queryAgent),
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
