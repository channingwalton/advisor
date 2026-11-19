import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";
import { Codex } from "@openai/codex-sdk";
import type { AgentSessionOptions } from "./agent.js";
import { CodexAgentSession, codexClientOptions, codexConfigServers, codexWorkingDirectory } from "./codex.js";
import {
  filesServer, filesServerReads, installCodexSandbox, realpathOrSelf, vendoredCodexPath, vendoredCodexRoot,
} from "./codexSandbox.js";
import { mergeConfig } from "./config.js";
import { STUB_MCP, SYNTHETIC_HOME_ROOT } from "./fakeModel.js";
import { cardLaneOptions } from "./lanes.js";
import { classifierOptions } from "./trigger.js";

// The Codex backend against the real vendored Codex CLI, spawned through the
// Seatbelt wrapper as in the app: which tools its Responses API request offers
// the model. Codex can't refuse a connector call by what it does, as the Claude
// backend's `mcpPermission` does, so a session that may only read through
// connectors must be offered none. A synthetic ~/.codex/config.toml stands in
// for the user's: a stub MCP server for their connectors, and a provider that
// points at a local fake endpoint, so no real credentials or network. The
// provider also guards the rest of the user's config: a session that dropped it
// would lose their model too, and never reach the fake. ChatGPT apps come with a
// ChatGPT login, so they can't show up here.
//
// Since CLI 0.166.0 a request does not list every tool. MCP tools are always
// deferred, and a code-mode model reaches most tools only from inside the
// JavaScript of its `exec` tool. So the fake model also probes: in code mode it
// calls `exec` to list `ALL_TOOLS`, and in either mode it tries to read a
// resource from the stub server, which reaches it only while it is enabled.
//
// A prompt whose name starts with `shell` probes the shell instead: the fake
// model runs `SHELL_COMMAND` through `exec_command`, from code mode's `exec` or
// directly, and the next request carries what the command printed. Under
// Advisor's profile no command runs (#118).
//
// A prompt whose name starts with `files` asks Advisor's own Read (#120) for
// each of `FILE_TARGETS`: from code mode's `exec`, or, on a classic model,
// through `tool_search` and then one call for each file.

/// Seatbelt and the vendored darwin binary; CI runs the sidecar on Linux.
const darwin = { skip: process.platform !== "darwin" ? "requires macOS and the darwin Codex CLI" : false };

let home: string;
/// The folder of the stub connector: a readable folder, or the Seatbelt
/// profile refuses the connector its own script (GHSA-6xc8-f55f-jxqr).
let connectorsDir: string;
/// A folder of notes, readable in the tests of Advisor's file tools.
let notesDir: string;
let server: http.Server;
/// What a session could use, by the prompt that sent it: the names of the tools
/// it was offered, what a read from the stub server's resources returned
/// (undefined when no tool could try), and what the shell probe printed
/// (undefined when no shell was offered).
interface Offered {
  tools: string[];
  stub?: string;
  shell?: string;
  /// What Advisor's Read returned for each of `FILE_TARGETS`, for a `files` prompt.
  files?: string[];
}
const offered = new Map<string, Offered>();

/// The call id of the fake model's probe, so its output is found in the next request.
const PROBE = "probe";
const STUB_READ = { server: "stub", uri: "stub://probe" };
/// Run by code mode's `exec`: the nested tools, and a read from the stub server.
const CODE_PROBE = `let stub;
try { stub = JSON.stringify(await tools.read_mcp_resource(${JSON.stringify(STUB_READ)})); } catch (e) { stub = String(e); }
text(JSON.stringify({ tools: ALL_TOOLS.map((t) => t.name), stub }));`;

/// What the files in the synthetic home hold: a note that a card may read, and
/// a key under `~/.ssh`, which the Seatbelt profile denies.
const NOTE = "note-118-readable";
const KEY = "key-118-secret";
/// A read-only shell command: the note, then the key. Set in `before`, because
/// the paths are in the synthetic home.
let SHELL_COMMAND: string;
/// What a `files` prompt asks Advisor's Read for, in order: a note in a
/// readable folder, the key, and Codex's config, which the profile lets the
/// CLI read and the policy refuses. Set in `before`.
let FILE_TARGETS: string[];
/// Run by code mode's `exec`: Advisor's Read of each file, as a JSON list.
const codeFiles = (): string => `const out = [];
for (const file_path of ${JSON.stringify(FILE_TARGETS)}) {
  try { out.push(JSON.stringify(await tools.mcp__advisor__Read({ file_path }))); } catch (e) { out.push("THREW " + String(e)); }
}
text(JSON.stringify(out));`;
/// Run by code mode's `exec`: the shell command, through the nested tool.
const codeShell = (): string => `let out;
try { out = await tools.exec_command(${JSON.stringify({ cmd: SHELL_COMMAND })}); } catch (e) { out = String(e); }
text(typeof out === "string" ? out : JSON.stringify(out));`;

type Tool = { name?: string; type: string; tools?: Tool[] };
type InputItem = { type?: string; call_id?: string; output?: unknown; tools?: Tool[] };

/// The tools a request offers, by bare name: its `tools`, and the namespaced
/// tools of its `additional_tools` input item.
function requestTools(body: { input?: InputItem[]; tools?: Tool[] }): string[] {
  const extra = (body.input ?? []).filter((i) => i.type === "additional_tools").flatMap((i) => i.tools ?? []);
  return [...(body.tools ?? []), ...extra].flatMap((t) => t.tools ?? [t]).map((t) => t.name ?? t.type);
}

/// The text of a tool output: a string, or a list of text items.
function outputText(output: unknown): string {
  if (typeof output === "string") return output;
  return Array.isArray(output) ? output.map((o: { text?: string }) => o.text ?? "").join("\n") : "";
}

/// Answer a Responses API request with finished items.
function respond(res: http.ServerResponse, ...items: object[]): void {
  const id = "resp_test";
  const usage = {
    input_tokens: 1, input_tokens_details: { cached_tokens: 0 },
    output_tokens: 1, output_tokens_details: { reasoning_tokens: 0 }, total_tokens: 2,
  };
  const events = [
    { type: "response.created", response: { id } },
    ...items.map((item, i) => ({ type: "response.output_item.done", output_index: i, item })),
    { type: "response.completed", response: { id, usage } },
  ];
  res.writeHead(200, { "content-type": "text/event-stream" });
  for (const e of events) res.write(`event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`);
  res.end();
}

const message = (text: string) => ({
  type: "message", id: "msg_test", role: "assistant", status: "completed",
  content: [{ type: "output_text", text, annotations: [] }],
});

/// Record what a request offers and, on the first request of a prompt, probe:
/// code mode lists its nested tools through `exec`; otherwise, a session with
/// `read_mcp_resource` reads from the stub. A shell prompt runs the shell
/// command instead. The probe's output arrives in the next request, and the
/// turn then ends.
function answer(res: http.ServerResponse, body: { input?: InputItem[]; tools?: Tool[] }): void {
  // The last prompt: a resumed thread sends its earlier turns too.
  const prompt = [...JSON.stringify(body.input).matchAll(/PROMPT:(\w+)/g)].at(-1)?.[1];
  const done = message('{"triggers":[]}');
  if (!prompt) return respond(res, done);
  // The last probe output: a resumed thread sends its earlier turns' too.
  const result = (body.input ?? []).filter((i) => i.type?.endsWith("_output") && i.call_id === PROBE).at(-1);
  const entry = offered.get(prompt);
  if (entry && prompt.startsWith("files")) return answerFiles(res, body, entry);
  if (result && entry && prompt.startsWith("shell")) {
    entry.shell = outputText(result.output);
    return respond(res, done);
  }
  if (result && entry) {
    const text = outputText(result.output);
    const json = text.split("\n").find((line) => line.startsWith("{\"tools\""));
    if (json) {
      const probe = JSON.parse(json) as { tools: string[]; stub?: string };
      entry.tools.push(...probe.tools);
      entry.stub = probe.stub;
    } else {
      entry.stub = text;
    }
    return respond(res, done);
  }
  if (entry) return respond(res, done);
  const tools = requestTools(body);
  const fresh: Offered = { tools };
  offered.set(prompt, fresh);
  if (prompt.startsWith("files")) return answerFiles(res, body, fresh);
  if (prompt.startsWith("shell")) {
    if (tools.includes("exec")) {
      return respond(res, { type: "custom_tool_call", id: "ctc_probe", call_id: PROBE, name: "exec", input: codeShell(), status: "completed" });
    }
    if (tools.includes("exec_command")) {
      const args = JSON.stringify({ cmd: SHELL_COMMAND });
      return respond(res, { type: "function_call", id: "fc_probe", call_id: PROBE, name: "exec_command", arguments: args, status: "completed" });
    }
    return respond(res, done);
  }
  if (tools.includes("exec")) {
    return respond(res, { type: "custom_tool_call", id: "ctc_probe", call_id: PROBE, name: "exec", input: CODE_PROBE, status: "completed" });
  }
  if (tools.includes("read_mcp_resource")) {
    const args = JSON.stringify(STUB_READ);
    return respond(res, { type: "function_call", id: "fc_probe", call_id: PROBE, name: "read_mcp_resource", arguments: args, status: "completed" });
  }
  respond(res, done);
}

/// The `files` probe, one step for each request: code mode reads every file
/// in one `exec`; a classic model searches for the tools, then calls Read for
/// each file at once. The request after the reads records their outputs.
function answerFiles(res: http.ServerResponse, body: { input?: InputItem[] }, entry: Offered): void {
  // This turn's items only: a resumed thread sends its earlier turns' too.
  const all = body.input ?? [];
  const input = all.slice(Math.max(all.map((i) => JSON.stringify(i).includes("PROMPT:")).lastIndexOf(true), 0));
  const output = (id: string) => input.find((i) => i.call_id === id && i.type?.endsWith("_output"));
  const code = output(PROBE);
  if (code) {
    const json = outputText(code.output).split("\n").find((line) => line.startsWith("["));
    entry.files = json ? (JSON.parse(json) as string[]) : [outputText(code.output)];
    return respond(res, message("done"));
  }
  const reads = FILE_TARGETS.map((_, i) => output(`read${i}`));
  if (reads.every((r) => r !== undefined)) {
    entry.files = reads.map((r) => outputText(r!.output));
    return respond(res, message("done"));
  }
  if (entry.tools.includes("exec")) {
    return respond(res, { type: "custom_tool_call", id: "ctc_probe", call_id: PROBE, name: "exec", input: codeFiles(), status: "completed" });
  }
  if (input.some((i) => i.type === "tool_search_output")) {
    return respond(res, ...FILE_TARGETS.map((file_path, i) => ({
      type: "function_call", id: `fc_read${i}`, call_id: `read${i}`, namespace: "mcp__advisor", name: "Read",
      arguments: JSON.stringify({ file_path }), status: "completed",
    })));
  }
  respond(res, {
    type: "tool_search_call", id: "ts_probe", call_id: "search", execution: "client",
    arguments: { query: "read a local file" }, status: "completed",
  });
}

before(async () => {
  if (darwin.skip) return;
  home = realpathOrSelf(fs.mkdtempSync(path.join(SYNTHETIC_HOME_ROOT, "advisor-sdk-codex-")));
  const codexHome = path.join(home, ".codex");
  fs.mkdirSync(codexHome);
  fs.mkdirSync(path.join(home, "sandbox"));
  fs.mkdirSync(path.join(home, ".ssh"));
  const note = path.join(home, "notes.md");
  const key = path.join(home, ".ssh", "id_test");
  fs.writeFileSync(note, `${NOTE}\n`);
  fs.writeFileSync(key, `${KEY}\n`);
  SHELL_COMMAND = `cat ${note}; cat ${key}`;
  notesDir = path.join(home, "Notes");
  fs.mkdirSync(notesDir);
  fs.writeFileSync(path.join(notesDir, "n.md"), `${NOTE}\n`);
  FILE_TARGETS = [path.join(notesDir, "n.md"), key, path.join(codexHome, "config.toml")];
  connectorsDir = path.join(home, "connectors");
  fs.mkdirSync(connectorsDir);
  const stub = path.join(connectorsDir, "stub-mcp.mjs");
  fs.writeFileSync(stub, STUB_MCP);
  server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      if (req.method !== "POST" || !req.url?.endsWith("/responses")) {
        res.writeHead(404);
        res.end();
        return;
      }
      answer(res, JSON.parse(raw) as { input?: InputItem[]; tools?: Tool[] });
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as { port: number };
  // The fake as a provider of the user's own, and a user MCP server, as
  // `codex mcp add` writes it. The provider sends HTTP only: the built-in one
  // tries a WebSocket first, and each failed attempt is an `error` event, which
  // ends the turn.
  fs.writeFileSync(path.join(codexHome, "config.toml"), [
    'model_provider = "fake"',
    "",
    "[model_providers.fake]",
    'name = "fake"',
    `base_url = "http://127.0.0.1:${port}/v1"`,
    'env_key = "FAKE_API_KEY"',
    'wire_api = "responses"',
    "supports_websockets = false",
    "",
    "[mcp_servers.stub]",
    `command = ${JSON.stringify(process.execPath)}`,
    `args = [${JSON.stringify(stub)}]`,
    "",
  ].join("\n"));
});

after(() => {
  if (darwin.skip) return;
  server.close();
  fs.rmSync(home, { recursive: true, force: true });
});

/// Run one turn with `opts` and return what it could use. The profile lets the
/// CLI read `readable` in the synthetic home.
async function offeredTools(
  prompt: string,
  given: AgentSessionOptions,
  readable: string[] = [connectorsDir]
): Promise<Offered> {
  const opts = { ...given, home };
  const cwd = codexWorkingDirectory(opts);
  fs.mkdirSync(cwd, { recursive: true });
  const env = {
    PATH: process.env.PATH ?? "",
    TMPDIR: os.tmpdir(),
    HOME: home,
    CODEX_HOME: path.join(home, ".codex"),
    FAKE_API_KEY: "sk-test",
  };
  const sandbox = path.join(home, "sandbox");
  const wrapper = installCodexSandbox(sandbox, home, vendoredCodexPath(), {
    folders: readable, cliRoot: vendoredCodexRoot(), cwd, ownTools: filesServerReads(sandbox),
  });
  const client = await codexClientOptions(
    opts, {}, wrapper, (cli, cwd) => codexConfigServers(cli, cwd, env), filesServer(sandbox, home)
  );
  const s = new CodexAgentSession(opts, (threadOptions) => new Codex({ ...client, env }).startThread(threadOptions));
  try {
    const r = await s.run(`PROMPT:${prompt}`, undefined, 60_000);
    assert.equal(r.error, undefined, `${prompt}: ${r.error}`);
  } finally {
    s.reset();
  }
  const tools = offered.get(prompt);
  assert.ok(tools, `${prompt}: the CLI never called the model`);
  return tools;
}

/// Ask the built sidecar one question on Codex, as the app does, and return what
/// it could use. This is the app's own path to a Codex client — the session sets
/// it up — where offeredTools builds the client itself.
async function sidecarTools(prompt: string, allowMcpActions: boolean): Promise<Offered> {
  return (await sidecarTurns([{ prompt, readable: [connectorsDir] }], allowMcpActions))[0];
}

/// Ask the built sidecar one question for each step, in turn, and return what
/// each could use. Before each question, config.json lists the step's readable
/// folders, as an edit in the Files tab would leave it, and the step's other
/// settings.
async function sidecarTurns(
  steps: { prompt: string; readable: string[]; settings?: Record<string, unknown> }[],
  allowMcpActions: boolean
): Promise<Offered[]> {
  const advisor = path.join(home, "Library", "Application Support", "Advisor");
  fs.mkdirSync(advisor, { recursive: true });
  const listing = (readable: string[], settings: Record<string, unknown> = {}): void => fs.writeFileSync(
    path.join(advisor, "config.json"),
    JSON.stringify({ provider: "codex", allowMcpActions, readableFolders: readable, ...settings })
  );
  listing(steps[0]?.readable ?? [], steps[0]?.settings);
  const sidecar = spawn(process.execPath, [fileURLToPath(new URL("./main.js", import.meta.url))], {
    env: { PATH: process.env.PATH ?? "", TMPDIR: os.tmpdir(), HOME: home, FAKE_API_KEY: "sk-test" },
  });
  let card: ((frame: { state: string; body: string }) => void) | undefined;
  readline.createInterface({ input: sidecar.stdout }).on("line", (line) => {
    const frame = JSON.parse(line) as { type: string; state?: string; body?: string };
    if (frame.type === "card_update" && frame.state !== "pending" && frame.state !== "streaming") {
      card?.({ state: frame.state ?? "", body: frame.body ?? "" });
    }
  });
  const used: Offered[] = [];
  try {
    for (const [i, step] of steps.entries()) {
      listing(step.readable, step.settings);
      // The questions go one at a time, so the next finished card is this one.
      const finished = new Promise<{ state: string; body: string }>((resolve) => (card = resolve));
      sidecar.stdin.write(JSON.stringify({ type: "query", id: `q${i}`, text: `PROMPT:${step.prompt}` }) + "\n");
      const frame = await finished;
      assert.equal(frame.state, "done", `${step.prompt}: ${frame.body}`);
      const tools = offered.get(step.prompt);
      assert.ok(tools, `${step.prompt}: the CLI never called the model`);
      used.push(tools);
    }
  } finally {
    sidecar.kill();
  }
  return used;
}

/// A model that reaches its tools through code mode's `exec`, as current models do.
const CODE_MODE_MODEL = "gpt-6.1-sol";
/// A model offered its tools directly (`tool_mode` null in the CLI's catalogue).
const CLASSIC_MODEL = "gpt-5.5";
const MODELS = [CODE_MODE_MODEL, CLASSIC_MODEL];

/// Whether the stub server answered the probe's read: the CLI fails a read from
/// a disabled server before it asks the server.
const reachesStub = (o: Offered): boolean => o.stub !== undefined && !/unknown MCP server 'stub'/.test(o.stub);

/// The connectors a session could use: tools of an MCP server, and the stub
/// server through the resource tools.
const connectors = (o: Offered): string[] => [
  ...o.tools.filter((t) => t.startsWith("mcp__")),
  ...(reachesStub(o) ? [`stub resource read: ${o.stub}`] : []),
];

const show = (o: Offered): string => `tools: ${o.tools.join(", ")}; stub read: ${o.stub}`;

test("#codex-connectors a card lane allowed connector actions is offered the stub connector and the shell", darwin, async () => {
  // The control: without it, the absences below could mean the stub never loaded.
  const o = await offeredTools("actions", cardLaneOptions(mergeConfig({ allowMcpActions: true, model: CODE_MODE_MODEL }), "research0"));
  assert.ok(o.tools.includes("mcp__stub__lookup"), show(o));
  assert.ok(o.tools.includes("exec_command"), show(o));
  assert.ok(reachesStub(o), show(o));
  // A classic model is offered MCP tools through tool_search, and the resource tools directly.
  const classic = await offeredTools("actionsClassic", cardLaneOptions(mergeConfig({ allowMcpActions: true, model: CLASSIC_MODEL }), "research0"));
  assert.ok(reachesStub(classic), show(classic));
});

// The cost of the read allowlist: a connector that reads its own files in the
// home folder does not start unless they are in a readable folder. The turn
// still runs.
test("#codex-readable-folders a connector whose files are in no readable folder does not start", darwin, async () => {
  const o = await offeredTools("unlistedConnector", cardLaneOptions(mergeConfig({ allowMcpActions: true, model: CODE_MODE_MODEL }), "research0"), []);
  // Node cannot read the server's script, so the server closes before its
  // handshake. (`reachesStub` counts that as a reach: the CLI asked for it.)
  assert.match(o.stub ?? "", /MCP startup failed/, show(o));
  assert.ok(!o.tools.includes("mcp__stub__lookup"), show(o));
});

// The sidecar writes the profile before each Codex turn, from config.json, and
// each turn starts a new CLI with its connectors: a folder that the user
// removes is refused from the next question on.
test("#codex-readable-folders the sidecar's next Codex turn refuses a folder that the user removed", { ...darwin, timeout: 90_000 }, async () => {
  const [listed, removed] = await sidecarTurns([
    { prompt: "sidecarListed", readable: [connectorsDir] },
    { prompt: "sidecarRemoved", readable: [] },
  ], true);
  assert.ok(reachesStub(listed) && !/MCP startup failed/.test(listed.stub ?? ""), show(listed));
  assert.match(removed.stub ?? "", /MCP startup failed/, show(removed));
});

/// The connectors a session could use, but Advisor's own file tools.
const userConnectors = (o: Offered): string[] => connectors(o).filter((t) => !t.startsWith("mcp__advisor__"));

test("#codex-connectors a card lane without connector actions is offered no connectors but Advisor's file tools", darwin, async () => {
  for (const [i, model] of MODELS.entries()) {
    const o = await offeredTools(`card${i}`, cardLaneOptions(mergeConfig({ model }), "research0"));
    assert.deepEqual(userConnectors(o), [], `${model}: ${show(o)}`);
    // It is still offered the shell, though no command runs under the profile (#118).
    assert.ok(o.tools.includes("exec_command"), `${model}: ${show(o)}`);
  }
});

test("#codex-shell a card lane's shell command fails closed under the Seatbelt profile", darwin, async () => {
  // The CLI's read-only mode cannot apply its own profile inside Advisor's, so
  // no command runs: not the read of an ordinary note, nor of a denied key.
  // A command that runs fails this test: read DESIGN.md (*Codex shell stays
  // closed*) before you accept it.
  for (const [i, model] of MODELS.entries()) {
    const o = await offeredTools(`shell${i}`, cardLaneOptions(mergeConfig({ model }), "research0"));
    const shown = `${model}: shell printed ${JSON.stringify(o.shell)}`;
    assert.ok(o.shell !== undefined, shown);
    assert.match(o.shell, /sandbox_apply: Operation not permitted/, shown);
    assert.ok(!o.shell.includes(NOTE), shown);
    assert.ok(!o.shell.includes(KEY), shown);
  }
});

test("#codex-connectors the sidecar's own Codex lanes follow the connector-actions toggle", { ...darwin, timeout: 60_000 }, async () => {
  const allowed = await sidecarTools("sidecarActions", true);
  assert.ok(allowed.tools.includes("mcp__stub__lookup"), show(allowed));
  const o = await sidecarTools("sidecar", false);
  assert.deepEqual(userConnectors(o), [], show(o));
});

/// Advisor's Read gave the note, and refused the key and Codex's config: the
/// profile lets the CLI read the config, so the policy refused it.
function assertFileReads(o: Offered, label: string): void {
  const shown = `${label}: ${JSON.stringify(o.files)}`;
  assert.equal(o.files?.length, FILE_TARGETS.length, shown);
  const [note, key, config] = o.files!;
  assert.ok(note.includes(NOTE), shown);
  for (const refused of [key, config]) assert.match(refused, /Access denied/, shown);
  assert.ok(!key.includes(KEY), shown);
  assert.ok(!config.includes("model_provider"), shown);
}

test("#codex-files a card lane reads a note through Advisor's Read, and not a store, with connector actions on and off", { ...darwin, timeout: 120_000 }, async () => {
  for (const [i, model] of MODELS.entries()) {
    for (const allowMcpActions of [false, true]) {
      const lane = cardLaneOptions(mergeConfig({ model, allowMcpActions }), "research0");
      const o = await offeredTools(`files${i}${allowMcpActions ? "on" : "off"}`, lane, [connectorsDir, notesDir]);
      assertFileReads(o, `${model}, connector actions ${allowMcpActions ? "on" : "off"}`);
    }
  }
});

// The sidecar's own path: its file tools, and the folder list that it writes
// before each turn with the profile.
test("#codex-files the sidecar's Codex card reads a note through Advisor's Read until the user removes its folder", { ...darwin, timeout: 90_000 }, async () => {
  const [listed, removed] = await sidecarTurns([
    { prompt: "filesSidecarListed", readable: [connectorsDir, notesDir] },
    { prompt: "filesSidecarRemoved", readable: [connectorsDir] },
  ], false);
  assertFileReads(listed, "listed");
  assert.match(removed.files?.[0] ?? "", /Access denied/, JSON.stringify(removed.files));
  assert.ok(!(removed.files?.[0] ?? "").includes(NOTE), JSON.stringify(removed.files));
});

// The session folder reaches the Codex profile and Advisor's file tools through
// the same list as the readable folders (issue #154). Here the session folder
// is the notes folder.
test("#past-sessions the sidecar's Codex card reads a past session while the toggle is on, and not once it is off", { ...darwin, timeout: 90_000 }, async () => {
  const [on, off] = await sidecarTurns([
    { prompt: "filesPastSessionsOn", readable: [connectorsDir], settings: { readPastSessions: true, sessionDir: notesDir } },
    { prompt: "filesPastSessionsOff", readable: [connectorsDir], settings: { readPastSessions: false, sessionDir: notesDir } },
  ], false);
  assertFileReads(on, "on");
  assert.match(off.files?.[0] ?? "", /Access denied/, JSON.stringify(off.files));
  assert.ok(!(off.files?.[0] ?? "").includes(NOTE), JSON.stringify(off.files));
});

/// What no setting removes, each inert here: code mode's `exec` runs JavaScript
/// with no file system or network, and reaches only the tools in this list;
/// `wait` waits for an `exec`; `update_plan` has no effect;
/// `request_user_input` fails in exec mode; `request_user_input_async` only
/// posts its questions as a message; `apply_patch` is refused by read-only mode
/// and the Seatbelt profile; `view_image` reads what the profile allows;
/// `clock__curr_time` reads the clock; and `tool_search` and the MCP resource
/// tools have no connectors to reach (each test checks the stub). A CLI upgrade
/// that offers anything else fails the classifier test.
const INERT = [
  "apply_patch", "clock__curr_time", "exec", "list_mcp_resource_templates", "list_mcp_resources", "read_mcp_resource",
  "request_user_input", "request_user_input_async", "tool_search", "update_plan", "view_image", "wait",
];

test("#classifier-no-tools a card lane on a sub-agent model is offered sub-agents", darwin, async () => {
  // The control for the next test: the model, not the features, turns these on.
  const o = await offeredTools("agents", cardLaneOptions(mergeConfig({ model: CODE_MODE_MODEL }), "research0"));
  assert.ok(o.tools.includes("spawn_agent"), show(o));
});

test("#classifier-no-tools the Codex classifier is offered no shell, connectors, goals or sub-agents", darwin, async () => {
  for (const [i, model] of MODELS.entries()) {
    const o = await offeredTools(`classify${i}`, classifierOptions(mergeConfig({ model })));
    assert.deepEqual(o.tools.filter((t) => !INERT.includes(t)), [], `${model}: ${show(o)}`);
    assert.deepEqual(connectors(o), [], `${model}: ${show(o)}`);
  }
});
