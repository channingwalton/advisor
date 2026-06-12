import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { log } from "./protocol.js";

export interface AdvisorConfig {
  /// Appended to the research agents' system prompt.
  extraInstructions: string;
  /// conservative | balanced | eager
  triggerSensitivity: string;
  /// Which trigger kinds are enabled.
  triggers: { question: boolean; context: boolean; factcheck: boolean };
  maxTriggersPerPass: number;
  classifierModel: string;
  /// "" = SDK default
  researchModel: string;
  /// Allow MCP connector tools that take actions (send/create/update/...).
  /// Read/search connector tools are always allowed.
  allowMcpActions: boolean;
}

const DEFAULTS: AdvisorConfig = {
  extraInstructions: "",
  triggerSensitivity: "balanced",
  triggers: { question: true, context: true, factcheck: true },
  maxTriggersPerPass: 2,
  classifierModel: "haiku",
  researchModel: "",
  allowMcpActions: false,
};

const CONFIG_PATH = `${homedir()}/Library/Application Support/Advisor/config.json`;

export function loadConfig(): AdvisorConfig {
  try {
    const raw = JSON.parse(readFileSync(CONFIG_PATH, "utf8")) as Partial<AdvisorConfig>;
    return {
      ...DEFAULTS,
      ...raw,
      triggers: { ...DEFAULTS.triggers, ...(raw.triggers ?? {}) },
    };
  } catch {
    log("no config.json, using defaults");
    return { ...DEFAULTS };
  }
}
