import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

// The shutdown contract with the app (SidecarManager.discardProcess): the app
// closes the sidecar's stdin and the sidecar exits at once — through Node's
// exit handlers, where the Agent SDK kills the CLI processes it spawned. (A
// SIGTERM would skip those and orphan them; the app sends one only as a late
// backstop.) The sidecar used to wait until its lanes were idle first, which
// nothing needed: the app has already failed every in-flight card by then.
test("#shutdown the sidecar exits promptly when its stdin closes", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "advisor-stdin-"));
  const sidecar = spawn(process.execPath, [fileURLToPath(new URL("./main.js", import.meta.url))], {
    env: { PATH: process.env.PATH ?? "", TMPDIR: os.tmpdir(), HOME: home },
    stdio: ["pipe", "pipe", "pipe"],
  });
  try {
    const exited = new Promise<number | null>((resolve) => sidecar.on("exit", (code) => resolve(code)));
    const frames: string[] = [];
    const hello = new Promise<void>((resolve) => {
      readline.createInterface({ input: sidecar.stdout }).on("line", (line) => {
        frames.push(line);
        try {
          if ((JSON.parse(line) as { type: string }).type === "hello") resolve();
        } catch { /* a non-JSON line is not the hello; reported below if it never comes */ }
      });
    });
    // Timers that must not keep the test process alive once it has passed.
    const after = (ms: number, label: string) =>
      new Promise<string>((resolve) => setTimeout(() => resolve(label), ms).unref());
    const started = await Promise.race([
      hello.then(() => "hello"),
      exited.then((code) => `exited (${code}) before hello`),
      after(10_000, "no hello within 10 s"),
    ]);
    assert.equal(started, "hello", `${started}; stdout so far: ${frames.join(" | ")}`);
    sidecar.stdin.end();
    const code = await Promise.race([exited, after(2000, "still running after 2 s")]);
    assert.equal(code, 0, String(code));
  } finally {
    sidecar.kill();
    fs.rmSync(home, { recursive: true, force: true });
  }
});
