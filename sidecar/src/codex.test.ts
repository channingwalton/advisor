import { test } from "node:test";
import assert from "node:assert/strict";
import { codexThreadOptions } from "./codex.js";

const base = { name: "x", systemPrompt: "sp", allowedTools: [] as string[] };

test("codexThreadOptions sandboxes read-only with no approval", () => {
  const o = codexThreadOptions(base);
  assert.equal(o.sandboxMode, "read-only");
  assert.equal(o.approvalPolicy, "never");
  assert.equal(o.skipGitRepoCheck, true);
});

test("codexThreadOptions enables web only when a Web tool is allowed", () => {
  assert.equal(codexThreadOptions(base).webSearchEnabled, false);
  assert.equal(codexThreadOptions(base).networkAccessEnabled, false);
  const web = codexThreadOptions({ ...base, allowedTools: ["WebSearch", "Read"] });
  assert.equal(web.webSearchEnabled, true);
  assert.equal(web.networkAccessEnabled, true);
});

test("codexThreadOptions passes the model through and defaults cwd to home", () => {
  const o = codexThreadOptions({ ...base, model: "gpt-5-codex", cwd: "/tmp/work" });
  assert.equal(o.model, "gpt-5-codex");
  assert.equal(o.workingDirectory, "/tmp/work");
  assert.equal(codexThreadOptions(base).model, undefined);
  assert.notEqual(codexThreadOptions(base).workingDirectory, undefined);
});
