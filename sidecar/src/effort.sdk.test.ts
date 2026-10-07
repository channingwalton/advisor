import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import type { EffortLevel } from "@anthropic-ai/claude-agent-sdk";
import { AgentSession } from "./agent.js";
import { fakeModelQuery, sse } from "./fakeModel.js";

// The effort preference against the real bundled Claude CLI: what effort the
// Messages API request actually carries. The card lanes load the user's own
// settings, so without an explicit level they think at the user's
// `effortLevel` — measured at `xhigh` in real use (2026-10-07).

let home: string;
let server: http.Server;
/// The `output_config.effort` of each request, by model.
const sent = new Map<string, unknown>();

before(async () => {
  home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-sdk-effort-")));
  fs.mkdirSync(path.join(home, ".claude"));
  fs.writeFileSync(path.join(home, ".claude", "settings.json"), JSON.stringify({ effortLevel: "xhigh" }));
  server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      if (!req.url?.startsWith("/v1/messages")) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end("{}");
        return;
      }
      const body = JSON.parse(raw) as { model: string; output_config?: { effort?: unknown } };
      sent.set(body.model, body.output_config?.effort);
      sse(res, [{ type: "text", text: "ok" }], "end_turn");
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
});

after(() => {
  server.close();
  fs.rmSync(home, { recursive: true, force: true });
});

/// Run one turn on `model` and return the effort its request carried.
async function sentEffort(model: string, effort?: EffortLevel): Promise<unknown> {
  const { port } = server.address() as { port: number };
  const s = new AgentSession(
    { name: "sdk-effort", systemPrompt: "test", model, effort, allowedTools: [], home },
    fakeModelQuery(home, port)
  );
  try {
    const r = await s.run("hello", undefined, 30_000);
    assert.equal(r.error, undefined, `${model}: ${r.error}`);
  } finally {
    s.reset();
  }
  assert.ok(sent.has(model), `${model}: the CLI never called the model`);
  return sent.get(model);
}

test("#effort-pref unset, a card lane inherits the user's effortLevel", async () => {
  assert.equal(await sentEffort("claude-opus-4-7"), "xhigh");
});

test("#effort-pref a chosen level overrides the user's effortLevel", async () => {
  assert.equal(await sentEffort("claude-opus-4-6", "low"), "low");
});

test("#effort-pref a level the model lacks is lowered, not a failed card", async () => {
  // xhigh is Opus 4.7+ / Fable 5 only; elsewhere the CLI sends the nearest level.
  assert.equal(await sentEffort("claude-sonnet-4-6", "xhigh"), "high");
});
