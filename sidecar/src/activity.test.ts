import { test } from "node:test";
import assert from "node:assert/strict";
import { describeToolUse } from "./activity.js";

test("#card-activity a web search shows its query", () => {
  assert.equal(describeToolUse("WebSearch", { query: "Gemini maths benchmark" }), "Searching the web for “Gemini maths benchmark”");
});

test("#card-activity a web fetch shows the site, not the whole URL", () => {
  assert.equal(describeToolUse("WebFetch", { url: "https://www.example.com/a/long/path?q=1" }), "Reading example.com");
  assert.equal(describeToolUse("WebFetch", { url: "not a url" }), "Reading a web page");
});

test("#card-activity local reads and searches name the file or pattern", () => {
  assert.equal(describeToolUse("Read", { file_path: "/Users/me/Notes/Projects/Cedar.md" }), "Reading Cedar.md");
  assert.equal(describeToolUse("Grep", { pattern: "Cedar", path: "/Users/me/Notes" }), "Searching your files for “Cedar”");
  assert.equal(describeToolUse("Glob", { pattern: "**/*.md" }), "Looking for files matching **/*.md");
});

test("#card-activity a connector tool names the connector and the action", () => {
  assert.equal(describeToolUse("mcp__claude_ai_Slack__search_messages", {}), "Using Slack: search messages");
  assert.equal(describeToolUse("mcp__jira__get-issue", {}), "Using jira: get issue");
});

test("#card-activity a tool missing its input still gets a plain line", () => {
  assert.equal(describeToolUse("WebSearch", {}), "Searching the web");
  assert.equal(describeToolUse("Read", undefined), "Reading a file");
  assert.equal(describeToolUse("Grep", { pattern: 42 }), "Searching your files");
  assert.equal(describeToolUse("Glob", null), "Looking for files");
});

test("#card-activity loading tool schemas is not worth a line", () => {
  assert.equal(describeToolUse("ToolSearch", { query: "slack" }), undefined);
});

test("#card-activity an unknown tool is named as it is", () => {
  assert.equal(describeToolUse("SomethingNew", {}), "Using SomethingNew");
});

test("#card-activity a long query is shortened to one line", () => {
  const line = describeToolUse("WebSearch", { query: `${"word ".repeat(40)}\nend` })!;
  assert.ok(line.length <= 110, line);
  assert.ok(line.endsWith("…”"), line);
  assert.ok(!line.includes("\n"), line);
});
