import http from "node:http";
import os from "node:os";
import path from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { QueryFn } from "./agent.js";

// Test support for driving the real bundled Claude CLI against a local fake
// Messages API (the *.sdk.test.ts files). No real credentials or network.

/// Answer one Messages API request as a server-sent event stream of `content`
/// blocks (text or tool_use), ending with `stop`.
export function sse(res: http.ServerResponse, content: Record<string, unknown>[], stop: string): void {
  const events: Record<string, unknown>[] = [{
    type: "message_start",
    message: {
      id: "msg_test", type: "message", role: "assistant", model: "claude-test", content: [],
      stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 },
    },
  }];
  content.forEach((block, index) => {
    if (block.type === "text") {
      events.push({ type: "content_block_start", index, content_block: { type: "text", text: "" } });
      events.push({ type: "content_block_delta", index, delta: { type: "text_delta", text: block.text } });
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
/// config never loads.
export function fakeModelQuery(home: string, port: number): QueryFn {
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "",
    TMPDIR: os.tmpdir(),
    HOME: home,
    CLAUDE_CONFIG_DIR: path.join(home, ".claude"),
    ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
    ANTHROPIC_API_KEY: "sk-ant-test",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
  };
  return ((args: Parameters<QueryFn>[0]) =>
    query({ ...args, options: { ...args.options, env } })) as QueryFn;
}
