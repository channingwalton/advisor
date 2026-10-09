import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { AgentSession, type AgentSessionOptions } from "./agent.js";
import { mergeConfig } from "./config.js";
import { fakeModelQuery, sse, STUB_MCP } from "./fakeModel.js";
import { cardLaneOptions } from "./lanes.js";
import { classifierOptions } from "./trigger.js";

// The classifier against the real bundled Claude CLI: which tools its Messages
// API request offers the model. `allowedTools: []` only skips the permission
// prompt — the CLI still offered every built-in and connector tool, and the
// sandbox let reads and web searches through, so a classify sometimes ran
// Grep or WebSearch and took ~10 s instead of ~2 s (46 runs in the log by
// 2026-10-09). A stub MCP server in the synthetic home stands in for the
// user's connectors; no real credentials or network.

let home: string;
let server: http.Server;
/// The tool names each request offered, by the prompt that sent it.
const offered = new Map<string, string[]>();

type Message = { role: string; content: string | { type: string; text?: string }[] };

before(async () => {
  home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-sdk-classifier-")));
  const claudeDir = path.join(home, ".claude");
  fs.mkdirSync(claudeDir);
  const stub = path.join(home, "stub-mcp.mjs");
  fs.writeFileSync(stub, STUB_MCP);
  // A user-scope MCP server, as `claude mcp add --scope user` writes it.
  fs.writeFileSync(path.join(claudeDir, ".claude.json"), JSON.stringify({
    mcpServers: { stub: { type: "stdio", command: process.execPath, args: [stub] } },
  }));
  server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      if (!req.url?.startsWith("/v1/messages")) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end("{}");
        return;
      }
      const body = JSON.parse(raw) as { messages?: Message[]; tools?: { name: string }[] };
      const first = body.messages?.find((m) => m.role === "user")?.content;
      const text = typeof first === "string" ? first : (first ?? []).map((b) => b.text ?? "").join("\n");
      const prompt = text.match(/PROMPT:(\w+)/)?.[1];
      if (prompt && !offered.has(prompt)) offered.set(prompt, (body.tools ?? []).map((t) => t.name));
      sse(res, [{ type: "text", text: '{"triggers":[]}' }], "end_turn");
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
});

after(() => {
  server.close();
  fs.rmSync(home, { recursive: true, force: true });
});

/// Run one turn with `opts` and return the tool names its request offered.
async function offeredTools(prompt: string, opts: AgentSessionOptions): Promise<string[]> {
  const { port } = server.address() as { port: number };
  const s = new AgentSession({ ...opts, home }, fakeModelQuery(home, port));
  try {
    const r = await s.run(`PROMPT:${prompt}`, undefined, 30_000);
    assert.equal(r.error, undefined, `${prompt}: ${r.error}`);
  } finally {
    s.reset();
  }
  const tools = offered.get(prompt);
  assert.ok(tools, `${prompt}: the CLI never called the model`);
  return tools;
}

const config = mergeConfig({ model: "claude-sonnet-4-6" });

test("#classifier-no-tools a card lane is offered the stub connector and built-in tools", async () => {
  // The control: without it, an empty list below could mean the stub never loaded.
  const tools = await offeredTools("card", cardLaneOptions(config, "research0"));
  assert.ok(tools.includes("WebSearch"), `card lane tools: ${tools.join(", ")}`);
  assert.ok(tools.some((t) => t.startsWith("mcp__stub__")), `card lane tools: ${tools.join(", ")}`);
});

test("#classifier-no-tools the classifier is offered no tools, built-in or connector", async () => {
  assert.deepEqual(await offeredTools("classify", classifierOptions(config)), []);
});

test("#classifier-no-tools no tools keeps out connectors even when the user's settings load", async () => {
  // The classifier loads no settings, so the stub never reaches it either way;
  // a card lane's options load them, as the control shows.
  const opts = { ...cardLaneOptions(config, "research0"), noTools: true };
  assert.deepEqual(await offeredTools("strict", opts), []);
});
