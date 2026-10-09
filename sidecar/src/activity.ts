import path from "node:path";

/// What a researching card shows while the model thinks.
export const THINKING = "Thinking…";

const MAX_ARG = 80;

/// An argument on one short line: whitespace collapsed, long ones cut with "…".
function clip(value: string): string {
  const flat = value.replace(/\s+/g, " ").trim();
  return flat.length > MAX_ARG ? `${flat.slice(0, MAX_ARG).trimEnd()}…` : flat;
}

/// `input[key]` if it is a non-empty string.
function field(input: unknown, key: string): string | undefined {
  const v = (input as Record<string, unknown> | null | undefined)?.[key];
  return typeof v === "string" && v.trim() ? v : undefined;
}

function host(url: string | undefined): string | undefined {
  try {
    return url ? new URL(url).hostname.replace(/^www\./, "") || undefined : undefined;
  } catch {
    return undefined;
  }
}

/// The line a researching card shows for a tool call, e.g. `Searching the web
/// for “Cedar”`. Undefined for calls not worth showing (loading tool schemas).
export function describeToolUse(name: string, input: unknown): string | undefined {
  switch (name) {
    case "ToolSearch":
      return undefined;
    case "WebSearch": {
      const q = field(input, "query");
      return q ? `Searching the web for “${clip(q)}”` : "Searching the web";
    }
    case "WebFetch": {
      const h = host(field(input, "url"));
      return h ? `Reading ${h}` : "Reading a web page";
    }
    case "Read": {
      const f = field(input, "file_path");
      return f ? `Reading ${clip(path.basename(f))}` : "Reading a file";
    }
    case "Grep": {
      const p = field(input, "pattern");
      return p ? `Searching your files for “${clip(p)}”` : "Searching your files";
    }
    case "Glob": {
      const p = field(input, "pattern");
      return p ? `Looking for files matching ${clip(p)}` : "Looking for files";
    }
  }
  // Connector tools are `mcp__<server>__<tool>`; claude.ai connectors prefix
  // the server with `claude_ai_`.
  const mcp = name.match(/^mcp__(.+?)__(.+)$/);
  if (mcp) {
    const words = (s: string) => s.replace(/[_-]+/g, " ").trim();
    return `Using ${words(mcp[1].replace(/^claude_ai_/, ""))}: ${words(mcp[2])}`;
  }
  return `Using ${name}`;
}
