import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { AgentSession } from "./agent.js";
import { fakeModelQuery, sse } from "./fakeModel.js";

// Card streaming against the real bundled Claude CLI: the text deltas and tool
// calls the SDK actually delivers, not a hand-built message sequence. The fake
// model writes a preliminary line and makes two tool calls — one the sandbox
// allows, one it denies — then answers word by word.

const PRELIMINARY = "From your notes: nothing on Cedar.";
const ANSWER = "Cedar is the database migration.";

let home: string;
let server: http.Server;

type Message = { role: string; content: string | { type: string }[] };

before(async () => {
  home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-sdk-stream-")));
  for (const dir of [".claude", ".ssh", "Documents"]) fs.mkdirSync(path.join(home, dir));
  fs.writeFileSync(path.join(home, ".ssh", "synthetic-key"), "SECRET");
  // The user's own settings refuse a tool the sandbox allows.
  fs.writeFileSync(path.join(home, ".claude", "settings.json"), JSON.stringify({ permissions: { deny: ["Grep"] } }));
  server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      if (!req.url?.startsWith("/v1/messages")) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end("{}");
        return;
      }
      const body = JSON.parse(raw) as { messages?: Message[]; tools?: unknown[] };
      const last = body.messages?.at(-1)?.content;
      const answered = Array.isArray(last) && last.some((b) => b.type === "tool_result");
      if (!body.tools) sse(res, [{ type: "text", text: "ok" }], "end_turn");
      else if (answered) sse(res, [{ type: "text", text: ANSWER }], "end_turn");
      else if (raw.includes("REFUSED")) sse(res, [
        { type: "tool_use", id: "toolu_grep", name: "Grep", input: { path: path.join(home, "Documents"), pattern: "Cedar" } },
      ], "tool_use");
      else sse(res, [
        { type: "text", text: PRELIMINARY },
        { type: "tool_use", id: "toolu_glob", name: "Glob", input: { path: path.join(home, "Documents"), pattern: "*.md" } },
        { type: "tool_use", id: "toolu_read", name: "Read", input: { file_path: path.join(home, ".ssh", "synthetic-key") } },
      ], "tool_use");
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
});

after(() => {
  server.close();
  fs.rmSync(home, { recursive: true, force: true });
});

test("#card-token-stream #card-activity the real CLI streams text word by word and reports the call it ran", async () => {
  const { port } = server.address() as { port: number };
  const s = new AgentSession(
    { name: "sdk-stream", systemPrompt: "test", model: "claude-test", allowedTools: [], home },
    fakeModelQuery(home, port)
  );
  const text: string[] = [];
  const activity: string[] = [];
  try {
    const r = await s.run(
      "What is Cedar?",
      { onText: (acc) => text.push(acc), onActivity: (a) => activity.push(a) },
      30_000
    );
    assert.equal(r.error, undefined, r.error);
    assert.equal(r.text, ANSWER);
  } finally {
    s.reset();
  }
  // Partial text reached the card before its block was finished…
  assert.ok(text.includes(`${PRELIMINARY}\n\nCedar `), JSON.stringify(text));
  // …and each block appears once, the finished messages adding nothing more.
  assert.equal(text.at(-1), `${PRELIMINARY}\n\n${ANSWER}`);
  // The denied credential read never shows.
  assert.deepEqual(activity, ["Looking for files matching *.md"]);
});

// The sandbox allows the call, but the user's own settings refuse it. The CLI
// applies their deny rule before the PreToolUse gate runs, so no line goes up
// for a search that never ran (checked 2026-10-09).
test("#card-activity a call the user's settings refuse shows no activity line", async () => {
  const { port } = server.address() as { port: number };
  const s = new AgentSession(
    { name: "sdk-stream", systemPrompt: "test", model: "claude-test", allowedTools: [], home },
    fakeModelQuery(home, port)
  );
  const activity: string[] = [];
  try {
    const r = await s.run("REFUSED: what is Cedar?", { onActivity: (a) => activity.push(a) }, 30_000);
    assert.equal(r.error, undefined, r.error);
  } finally {
    s.reset();
  }
  assert.deepEqual(activity, []);
});
