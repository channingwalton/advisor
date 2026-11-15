import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { AgentSession } from "./agent.js";
import { fakeModelQuery, SYNTHETIC_HOME_ROOT } from "./fakeModel.js";

// #142 against the real bundled Claude CLI: a reset during a turn that never
// gets an answer must end the CLI process. The fake endpoint takes the
// request and never answers it, so the turn blocks and no `result` comes.

/// The pids of this process's descendants (the CLI, and its sandbox wrapper).
function descendants(): number[] {
  const rows = execFileSync("ps", ["-axo", "pid=,ppid="], { encoding: "utf8" })
    .trim().split("\n").map((l) => l.trim().split(/\s+/).map(Number));
  const found = new Set<number>([process.pid]);
  for (let grew = true; grew;) {
    grew = false;
    for (const [pid, ppid] of rows) {
      if (found.has(ppid) && !found.has(pid)) {
        found.add(pid);
        grew = true;
      }
    }
  }
  found.delete(process.pid);
  // `ps` itself is a child while it runs, so keep only live pids.
  return [...found].filter(alive);
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function until(what: string, ok: () => boolean, ms: number): Promise<void> {
  const end = Date.now() + ms;
  while (!ok()) {
    if (Date.now() > end) assert.fail(`timed out waiting for: ${what}`);
    await sleep(100);
  }
}

test("#142 reset() during a blocked turn ends the CLI process", async () => {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(SYNTHETIC_HOME_ROOT, "advisor-sdk-close-")));
  fs.mkdirSync(path.join(home, ".claude"));
  fs.mkdirSync(path.join(home, "work"));
  let asked = 0;
  const held: http.ServerResponse[] = [];
  const server = http.createServer((req, res) => {
    req.resume();
    if (!req.url?.startsWith("/v1/messages")) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end("{}");
      return;
    }
    asked++;
    held.push(res); // never answered
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as { port: number };
  const session = new AgentSession(
    {
      name: "sdk-close", systemPrompt: "test", model: "claude-test", allowedTools: [],
      cwd: path.join(home, "work"), home, readableFolders: () => [],
    },
    fakeModelQuery(home, port)
  );
  const unhandled: unknown[] = [];
  const onUnhandled = (e: unknown) => unhandled.push(e);
  process.on("unhandledRejection", onUnhandled);
  try {
    assert.deepEqual(descendants(), []);
    const run = session.run("hello", undefined, 60_000);
    await until("the turn reaches the model", () => asked > 0, 30_000);
    assert.ok(descendants().length > 0, "the CLI is running");

    session.reset();
    assert.equal((await run).error, "agent session reset");
    // close() ends stdin, then SIGTERM after 2 s, SIGKILL 5 s later.
    await until("the CLI process to end", () => descendants().length === 0, 15_000);

    // The session starts a new CLI afterwards.
    const second = session.run("again", undefined, 60_000);
    await until("the second turn reaches the model", () => asked > 1, 30_000);
    assert.ok(descendants().length > 0, "a new CLI is running");
    session.reset();
    assert.equal((await second).error, "agent session reset");
    await until("the second CLI to end", () => descendants().length === 0, 15_000);
    await sleep(200);
    assert.deepEqual(unhandled, []);
  } finally {
    process.off("unhandledRejection", onUnhandled);
    session.reset();
    for (const res of held) res.destroy();
    server.close();
    fs.rmSync(home, { recursive: true, force: true });
  }
});
