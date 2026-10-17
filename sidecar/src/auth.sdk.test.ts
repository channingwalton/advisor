import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { AgentSession } from "./agent.js";
import { fakeModelQuery } from "./fakeModel.js";

// The real bundled Claude CLI with no credentials at all — no login in the
// synthetic home, no API key in the environment. It does not call the API: it
// answers at once with a `success` result flagged `is_error`, its message in
// `result` and echoed as a synthetic assistant block. The session must report
// that as a failure with no answer text, so the card fails rather than present
// "Not logged in · Please run /login" as the answer (code review 2026-10-17).
// (A 401 from the API is a different path: the CLI retries it with backoff for
// longer than a task lives, so that one ends as a timeout.)
test("#result-error a logged-out CLI's result is a failure, not an answer", async (t) => {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-sdk-auth-")));
  fs.mkdirSync(path.join(home, ".claude"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  // Port 9 (discard): nothing answers, so the test fails loudly if the CLI does try the API.
  const session = new AgentSession(
    { name: "auth", systemPrompt: "", allowedTools: [], home, noTools: true, settingSources: [] },
    fakeModelQuery(home, 9, null)
  );
  const r = await session.run("Say hello.", undefined, 30_000);
  session.reset();
  assert.notEqual(r.error, "timed out",
    "the CLI tried the API, so it found credentials despite the synthetic HOME/CLAUDE_CONFIG_DIR");
  assert.equal(r.text, "", `text: ${JSON.stringify(r.text)}`);
  assert.match(r.error ?? "", /Not logged in|login/i);
});
