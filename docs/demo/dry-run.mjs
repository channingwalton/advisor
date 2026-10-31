// Sends the dialogue to the built sidecar as the app does during a take, and
// prints each line, trigger decision and card with its time from the start of
// the audio. Use it to tune dialogue.txt before a take: it needs no window and
// no audio, but it uses your config.json and your CLI login, as the app does.
//
// Usage: node docs/demo/dry-run.mjs   (after make-audio.sh and `npm run build`
// in sidecar/)
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const WARMUP_S = 5; // Listen is clicked this long before the audio starts.
const STT_LAG_S = 0.7; // An utterance is final this long after its speech ends.
const TAIL_S = 40; // Wait at most this long after the last line.

const lines = readFileSync(join(here, "out", "timeline.tsv"), "utf8")
  .trim()
  .split("\n")
  .slice(1)
  .map((row) => {
    const [, end, , text] = row.split("\t");
    return { end: Number(end), text };
  });
const context = readFileSync(join(here, "context.txt"), "utf8").trim();

const sidecar = spawn("node", [join(root, "sidecar", "dist", "main.js")], {
  stdio: ["pipe", "pipe", "pipe"],
});
const audioStart = Date.now() + WARMUP_S * 1000;
const at = () => `${((Date.now() - audioStart) / 1000).toFixed(1).padStart(6)} s`;
const send = (frame) => sidecar.stdin.write(JSON.stringify(frame) + "\n");

send({ type: "session_start", sessionId: "demo-dry-run", ts: Date.now() / 1000, context });
lines.forEach((line, i) => {
  setTimeout(() => {
    send({ type: "utterance", id: `u${i + 1}`, source: "them", text: line.text, ts: Date.now() / 1000 });
    console.log(`${at()}  heard  ${line.text}`);
  }, (WARMUP_S + line.end + STT_LAG_S) * 1000);
});

const cards = new Map();
const finished = (state) => ["done", "failed", "cancelled"].includes(state);

createInterface({ input: sidecar.stdout }).on("line", (raw) => {
  let frame;
  try {
    frame = JSON.parse(raw);
  } catch {
    return;
  }
  if (frame.type === "card") {
    cards.set(frame.id, { kind: frame.kind, title: frame.title, state: frame.state, body: "" });
    console.log(`${at()}  card   ${frame.kind}: ${frame.title}`);
  } else if (frame.type === "card_update" && cards.has(frame.id)) {
    const card = cards.get(frame.id);
    card.body = frame.body;
    if (finished(frame.state) && !finished(card.state)) {
      console.log(`${at()}  ${frame.state.padEnd(5)}  ${card.kind}: ${card.title}`);
    }
    card.state = frame.state;
  }
});
createInterface({ input: sidecar.stderr }).on("line", (line) => {
  if (/classify|shown/.test(line)) console.log(`${at()}  log    ${line}`);
});

// Stop when every card is finished, but not before 10 s after the last line.
const lastLine = audioStart + (lines.at(-1).end + STT_LAG_S) * 1000;
const deadline = lastLine + TAIL_S * 1000;
const poll = setInterval(() => {
  const settled = Date.now() > lastLine + 10_000 &&
    cards.size > 0 && [...cards.values()].every((c) => finished(c.state));
  if (!settled && Date.now() < deadline) return;
  clearInterval(poll);
  console.log(`\n${cards.size} card(s):`);
  for (const c of cards.values()) {
    console.log(`\n## ${c.kind}: ${c.title} (${c.state})\n${c.body}`);
  }
  sidecar.kill();
}, 500);
