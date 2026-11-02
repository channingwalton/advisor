# Supplied licence texts

Some npm packages that the app bundles ship without a licence file, but their
licences ask that copies carry the licence text. `App/package.sh` runs
`App/licences.sh`, which copies each folder here into the bundled package of
the same name, then fails the build if any bundled package still has no
licence file.

Each text is copied unchanged from upstream. A package that bundles other
programs gets their texts too, named `<program>.LICENSE`. The check does not
count a file with that name as the package's own licence:

| Package | Licence | Source |
|---|---|---|
| `@openai/codex` | Apache-2.0 | [`LICENSE`](https://github.com/openai/codex/blob/rust-v0.166.0/LICENSE) and [`NOTICE`](https://github.com/openai/codex/blob/rust-v0.166.0/NOTICE) at tag `rust-v0.166.0` |
| `@openai/codex-darwin-arm64` | Apache-2.0 | The same files: this package holds the Codex CLI binaries (`codex` and `codex-code-mode-host`) |
| `@openai/codex-darwin-arm64`: its `rg` | Unlicense OR MIT | `ripgrep.LICENSE`: [`LICENSE-MIT`](https://github.com/BurntSushi/ripgrep/blob/15.2.0/LICENSE-MIT) at tag `15.2.0`, the version bundled |

The Codex binary package also bundles a voice runtime
(`codex-resources/voice`: GStreamer, GLib and their libraries). It ships its
own texts in `voice/licenses` and `voice/NOTICE.md`, so it needs none here.
| `standardwebhooks` | MIT | [`libraries/LICENSE`](https://github.com/standard-webhooks/standard-webhooks/blob/c7cd8a9eadf9879d6dca345e168dc8d15d19e487/libraries/LICENSE) |

When the build names a package with no licence file, add a folder for it here
with the text from its upstream repository, and add a row to this table.
`licences.sh` never overwrites a file that a package ships. It warns when a
text here is no longer needed: the package now ships its own licence (remove
the supplied `LICENSE` and `NOTICE`, and keep any `<program>.LICENSE`), or the
app no longer bundles the package (remove its folder). Then update the table. `BundledLicencesTests` holds this folder to the packages that
`sidecar/package-lock.json` locks.
