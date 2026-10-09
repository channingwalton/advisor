import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";
import { Codex } from "@openai/codex-sdk";
import type { AgentSessionOptions } from "./agent.js";
import { CodexAgentSession, codexClientOptions, codexConfigServers } from "./codex.js";
import { installCodexSandbox, realpathOrSelf, vendoredCodexPath } from "./codexSandbox.js";
import { mergeConfig } from "./config.js";
import { STUB_MCP } from "./fakeModel.js";
import { cardLaneOptions } from "./lanes.js";
import { classifierOptions } from "./trigger.js";

// The Codex backend against the real vendored Codex CLI, spawned through the
// Seatbelt wrapper as in the app: which tools its Responses API request offers
// the model. Codex can't refuse a connector call by what it does, as the Claude
// backend's `mcpPermission` does, so a session that may only read through
// connectors must be offered none. A synthetic ~/.codex/config.toml stands in
// for the user's: a stub MCP server for their connectors, and a provider that
// points at a local fake endpoint, so no real credentials or network. The
// provider also guards the rest of the user's config: a session that dropped it
// would lose their model too, and never reach the fake. ChatGPT apps come with a
// ChatGPT login, so they can't show up here.

/// Seatbelt and the vendored darwin binary; CI runs the sidecar on Linux.
const darwin = { skip: process.platform !== "darwin" ? "requires macOS and the darwin Codex CLI" : false };

let home: string;
let server: http.Server;
/// The tool names each request offered, by the prompt that sent it.
const offered = new Map<string, string[]>();

/// Answer a Responses API request with one finished message.
function respond(res: http.ServerResponse, text: string): void {
  const id = "resp_test";
  const message = {
    type: "message", id: "msg_test", role: "assistant", status: "completed",
    content: [{ type: "output_text", text, annotations: [] }],
  };
  const usage = {
    input_tokens: 1, input_tokens_details: { cached_tokens: 0 },
    output_tokens: 1, output_tokens_details: { reasoning_tokens: 0 }, total_tokens: 2,
  };
  const events = [
    { type: "response.created", response: { id } },
    { type: "response.output_item.done", output_index: 0, item: message },
    { type: "response.completed", response: { id, usage } },
  ];
  res.writeHead(200, { "content-type": "text/event-stream" });
  for (const e of events) res.write(`event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`);
  res.end();
}

before(async () => {
  if (darwin.skip) return;
  home = realpathOrSelf(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-sdk-codex-")));
  const codexHome = path.join(home, ".codex");
  fs.mkdirSync(codexHome);
  fs.mkdirSync(path.join(home, "sandbox"));
  const stub = path.join(home, "stub-mcp.mjs");
  fs.writeFileSync(stub, STUB_MCP);
  server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      if (req.method !== "POST" || !req.url?.endsWith("/responses")) {
        res.writeHead(404);
        res.end();
        return;
      }
      const body = JSON.parse(raw) as { input?: unknown; tools?: { name?: string; type: string }[] };
      const prompt = JSON.stringify(body.input).match(/PROMPT:(\w+)/)?.[1];
      if (prompt && !offered.has(prompt)) offered.set(prompt, (body.tools ?? []).map((t) => t.name ?? t.type));
      respond(res, '{"triggers":[]}');
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as { port: number };
  // The fake as a provider of the user's own, and a user MCP server, as
  // `codex mcp add` writes it. The provider sends HTTP only: the built-in one
  // tries a WebSocket first, and each failed attempt is an `error` event, which
  // ends the turn.
  fs.writeFileSync(path.join(codexHome, "config.toml"), [
    'model_provider = "fake"',
    "",
    "[model_providers.fake]",
    'name = "fake"',
    `base_url = "http://127.0.0.1:${port}/v1"`,
    'env_key = "FAKE_API_KEY"',
    'wire_api = "responses"',
    "supports_websockets = false",
    "",
    "[mcp_servers.stub]",
    `command = ${JSON.stringify(process.execPath)}`,
    `args = [${JSON.stringify(stub)}]`,
    "",
  ].join("\n"));
});

after(() => {
  if (darwin.skip) return;
  server.close();
  fs.rmSync(home, { recursive: true, force: true });
});

/// Run one turn with `opts` and return the tool names its request offered.
async function offeredTools(prompt: string, opts: AgentSessionOptions): Promise<string[]> {
  const env = {
    PATH: process.env.PATH ?? "",
    TMPDIR: os.tmpdir(),
    HOME: home,
    CODEX_HOME: path.join(home, ".codex"),
    FAKE_API_KEY: "sk-test",
  };
  const wrapper = installCodexSandbox(path.join(home, "sandbox"), home, vendoredCodexPath());
  const client = await codexClientOptions(opts, {}, wrapper, (cli, cwd) => codexConfigServers(cli, cwd, env));
  const s = new CodexAgentSession(opts, (threadOptions) => new Codex({ ...client, env }).startThread(threadOptions));
  try {
    const r = await s.run(`PROMPT:${prompt}`, undefined, 60_000);
    assert.equal(r.error, undefined, `${prompt}: ${r.error}`);
  } finally {
    s.reset();
  }
  const tools = offered.get(prompt);
  assert.ok(tools, `${prompt}: the CLI never called the model`);
  return tools;
}

/// Ask the built sidecar one question on Codex, as the app does, and return the
/// tools its request offered. This is the app's own path to a Codex client —
/// the session sets it up — where offeredTools builds the client itself.
async function sidecarTools(prompt: string, allowMcpActions: boolean): Promise<string[]> {
  const advisor = path.join(home, "Library", "Application Support", "Advisor");
  fs.mkdirSync(advisor, { recursive: true });
  fs.writeFileSync(path.join(advisor, "config.json"), JSON.stringify({ provider: "codex", allowMcpActions }));
  const sidecar = spawn(process.execPath, [fileURLToPath(new URL("./main.js", import.meta.url))], {
    env: { PATH: process.env.PATH ?? "", TMPDIR: os.tmpdir(), HOME: home, FAKE_API_KEY: "sk-test" },
  });
  try {
    const finished = new Promise<{ state: string; body: string }>((resolve) => {
      readline.createInterface({ input: sidecar.stdout }).on("line", (line) => {
        const frame = JSON.parse(line) as { type: string; state?: string; body?: string };
        if (frame.type === "card_update" && frame.state !== "pending" && frame.state !== "streaming") {
          resolve({ state: frame.state ?? "", body: frame.body ?? "" });
        }
      });
    });
    sidecar.stdin.write(JSON.stringify({ type: "query", id: "q", text: `PROMPT:${prompt}` }) + "\n");
    const frame = await finished;
    assert.equal(frame.state, "done", `${prompt}: ${frame.body}`);
  } finally {
    sidecar.kill();
  }
  const tools = offered.get(prompt);
  assert.ok(tools, `${prompt}: the CLI never called the model`);
  return tools;
}

const isConnector = (t: string): boolean => t.startsWith("mcp__") || t.includes("mcp_resource");

test("#codex-connectors a card lane allowed connector actions is offered the stub connector and the shell", darwin, async () => {
  // The control: without it, the absences below could mean the stub never loaded.
  const tools = await offeredTools("actions", cardLaneOptions(mergeConfig({ allowMcpActions: true }), "research0"));
  assert.ok(tools.includes("mcp__stub"), `card lane tools: ${tools.join(", ")}`);
  assert.ok(tools.includes("exec_command"), `card lane tools: ${tools.join(", ")}`);
});

test("#codex-connectors a card lane without connector actions is offered no connectors", darwin, async () => {
  const tools = await offeredTools("card", cardLaneOptions(mergeConfig({}), "research0"));
  assert.deepEqual(tools.filter(isConnector), [], `card lane tools: ${tools.join(", ")}`);
  // It still reads local notes through the shell, as the Claude lanes do with Read/Grep.
  assert.ok(tools.includes("exec_command"), `card lane tools: ${tools.join(", ")}`);
});

test("#codex-connectors the sidecar's own Codex lanes follow the connector-actions toggle", { ...darwin, timeout: 60_000 }, async () => {
  const allowed = await sidecarTools("sidecarActions", true);
  assert.ok(allowed.includes("mcp__stub"), `query lane tools: ${allowed.join(", ")}`);
  const tools = await sidecarTools("sidecar", false);
  assert.deepEqual(tools.filter(isConnector), [], `query lane tools: ${tools.join(", ")}`);
});

/// What no setting removes, each inert here: update_plan has no effect,
/// request_user_input fails in exec mode, apply_patch is refused by read-only
/// mode and the Seatbelt profile, view_image reads what the profile allows, and
/// tool_search has no connectors to find. A CLI upgrade that offers anything
/// else fails the classifier tests.
const INERT = ["apply_patch", "request_user_input", "tool_search", "update_plan", "view_image"];

/// A model whose tools include sub-agents (`multi_agent_v1`); the CLI's default
/// for an API key has none.
const AGENT_MODEL = "gpt-6.1-sol";

test("#classifier-no-tools the Codex classifier is offered no shell, connectors or goals", darwin, async () => {
  const tools = await offeredTools("classify", classifierOptions(mergeConfig({})));
  assert.deepEqual(tools.filter((t) => !INERT.includes(t)), [], `classifier tools: ${tools.join(", ")}`);
});

test("#classifier-no-tools a card lane on a sub-agent model is offered sub-agents", darwin, async () => {
  // The control for the next test: the model, not the setting, decides this.
  const tools = await offeredTools("agents", cardLaneOptions(mergeConfig({ model: AGENT_MODEL }), "research0"));
  assert.ok(tools.includes("multi_agent_v1"), `card lane tools: ${tools.join(", ")}`);
});

test("#classifier-no-tools the Codex classifier on a sub-agent model is offered no sub-agents", darwin, async () => {
  const tools = await offeredTools("classifyAgents", classifierOptions(mergeConfig({ model: AGENT_MODEL })));
  assert.deepEqual(tools.filter((t) => !INERT.includes(t)), [], `classifier tools: ${tools.join(", ")}`);
});
