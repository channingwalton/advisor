import { test } from "node:test";
import assert from "node:assert/strict";
import { readPathAllowed, searchRootAllowed } from "./agent.js";

const HOME = "/home/u";

test("Read allows non-sensitive files under home (absolute and relative)", () => {
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/Documents/notes.txt"), true);
  assert.equal(readPathAllowed(HOME, HOME, "Documents/notes.txt"), true);
});

test("Read denies sensitive paths, including .codex", () => {
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.codex/auth.json"), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.codex-global-state.json"), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.ssh/id_rsa"), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.claude.json"), false);
  assert.equal(readPathAllowed(HOME, HOME, "/home/u/.config/gh/hosts.yml"), false);
});

test("Read denies paths outside home", () => {
  assert.equal(readPathAllowed(HOME, HOME, "/etc/passwd"), false);
  assert.equal(readPathAllowed(HOME, HOME, "../../etc/passwd"), false);
  assert.equal(readPathAllowed(HOME, HOME, 42), false); // non-string
});

test("search denies an unscoped home root (recursive-pattern exfil vector)", () => {
  // The bypass the review flagged: Glob {path:$HOME, pattern:".ssh/**"} and
  // Grep {path:$HOME, pattern:"PRIVATE KEY"} pass a path check but recurse into
  // secrets. Blocking the root closes it regardless of pattern.
  assert.equal(searchRootAllowed(HOME, HOME, HOME), false);
  assert.equal(searchRootAllowed(HOME, HOME, undefined), false); // defaults to cwd = home
  assert.equal(searchRootAllowed(HOME, HOME, ""), false);
});

test("search denies roots at or above any denied dir", () => {
  assert.equal(searchRootAllowed(HOME, HOME, "/home/u/.ssh"), false); // inside denied
  assert.equal(searchRootAllowed(HOME, HOME, "/home/u/.config"), false); // above .config/gh
});

test("search allows a scoped subtree with no secrets beneath", () => {
  assert.equal(searchRootAllowed(HOME, HOME, "/home/u/Documents"), true);
  assert.equal(searchRootAllowed(HOME, HOME, "Documents"), true);
});
