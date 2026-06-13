import { AgentSession, type Agent, type AgentSessionOptions } from "./agent.js";
import { CodexAgentSession } from "./codex.js";
import type { Provider } from "./config.js";
import { log } from "./protocol.js";

/// One agent backend. Adding a provider = one entry here (sidecar) plus the
/// matching descriptor in the app's Preferences (cross-language, so mirrored).
export interface ProviderSpec {
  id: Provider;
  label: string;
  create(opts: AgentSessionOptions): Agent;
}

export const PROVIDERS: Record<string, ProviderSpec> = {
  claude: { id: "claude", label: "Claude", create: (o) => new AgentSession(o) },
  codex: { id: "codex", label: "Codex", create: (o) => new CodexAgentSession(o) },
};

/// Build the agent backend for a component. Unknown provider ids fall back to
/// Claude (forward-compatible with configs written by a newer app).
export function createAgent(provider: Provider, opts: AgentSessionOptions): Agent {
  const spec = PROVIDERS[provider];
  if (!spec) {
    log(`unknown provider "${provider}", falling back to claude`);
    return PROVIDERS.claude.create(opts);
  }
  return spec.create(opts);
}
