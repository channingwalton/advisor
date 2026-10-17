import http from "node:http";
import os from "node:os";
import path from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { QueryFn } from "./agent.js";

// Test support for driving the real bundled Claude CLI against a local fake
// Messages API (the *.sdk.test.ts files). No real credentials or network.

let messages = 0;

/// Answer one Messages API request as a server-sent event stream of `content`
/// blocks (text or tool_use), ending with `stop`. Each response is a new
/// message, and text arrives a word at a time, as from the real API.
export function sse(res: http.ServerResponse, content: Record<string, unknown>[], stop: string): void {
  const events: Record<string, unknown>[] = [{
    type: "message_start",
    message: {
      id: `msg_test_${++messages}`, type: "message", role: "assistant", model: "claude-test", content: [],
      stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 },
    },
  }];
  content.forEach((block, index) => {
    if (block.type === "text") {
      events.push({ type: "content_block_start", index, content_block: { type: "text", text: "" } });
      for (const text of String(block.text).split(/(?<= )/)) {
        events.push({ type: "content_block_delta", index, delta: { type: "text_delta", text } });
      }
    } else {
      events.push({ type: "content_block_start", index, content_block: { ...block, input: {} } });
      events.push({
        type: "content_block_delta", index,
        delta: { type: "input_json_delta", partial_json: JSON.stringify(block.input) },
      });
    }
    events.push({ type: "content_block_stop", index });
  });
  events.push({ type: "message_delta", delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 1 } });
  events.push({ type: "message_stop" });
  res.writeHead(200, { "content-type": "text/event-stream" });
  for (const e of events) res.write(`event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`);
  res.end();
}

/// A `query` that runs the CLI in the synthetic `home` against the fake
/// endpoint on `port`, with a minimal environment so the developer's own Claude
/// config never loads. `apiKey: null` leaves the CLI with no credentials at all.
export function fakeModelQuery(home: string, port: number, apiKey: string | null = "sk-ant-test"): QueryFn {
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "",
    TMPDIR: os.tmpdir(),
    HOME: home,
    CLAUDE_CONFIG_DIR: path.join(home, ".claude"),
    ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
    ...(apiKey === null ? {} : { ANTHROPIC_API_KEY: apiKey }),
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
  };
  return ((args: Parameters<QueryFn>[0]) =>
    query({ ...args, options: { ...args.options, env } })) as QueryFn;
}

/// A minimal stdio MCP server with one tool, `lookup`, standing in for the
/// user's connectors (`mcp__stub__lookup` to the Claude CLI).
export const STUB_MCP = `
import readline from "node:readline";
const send = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const msg = JSON.parse(line);
  if (msg.id === undefined) return;
  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: {
      protocolVersion: msg.params.protocolVersion,
      capabilities: { tools: {} },
      serverInfo: { name: "stub", version: "1" },
    } });
  } else if (msg.method === "tools/list") {
    send({ jsonrpc: "2.0", id: msg.id, result: { tools: [
      { name: "lookup", description: "Look something up", inputSchema: { type: "object", properties: {} } },
    ] } });
  } else {
    send({ jsonrpc: "2.0", id: msg.id, result: {} });
  }
});
`;
