import readline from "node:readline";
import { mcpReply, readFolderList } from "./localFiles.js";

/// Advisor's own stdio MCP server for Codex card lanes (#120), started by the
/// Codex CLI under its Seatbelt profile (codex.ts): `node localFilesMcp.js
/// <home> <folder list file>`. The sidecar writes the folder list before each
/// turn (codexSandbox.ts), and each call reads it. The logic is in
/// localFiles.ts.
const [home, folderList] = process.argv.slice(2);
if (!home || !folderList) {
  process.stderr.write("usage: localFilesMcp.js <home> <folder list file>\n");
  process.exit(2);
}
const ctx = { home, cwd: process.cwd(), folders: () => readFolderList(folderList) };
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  let msg: unknown;
  try {
    msg = JSON.parse(line);
  } catch {
    return; // not JSON-RPC: nothing to answer
  }
  const reply = mcpReply(msg, ctx);
  if (reply) process.stdout.write(JSON.stringify(reply) + "\n");
});
