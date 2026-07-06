//! gist --schema — the machine-readable capability manifest.
//!
//! An agent (or a codegen step, or the `services/ai/tools` registry that should
//! eventually wire gist as a first-class tool) shouldn't have to scrape `--help`
//! prose to learn what gist can do. `gist --schema` emits a stable JSON document:
//! every public verb, every NATIVE (Set B) flag with its type / default /
//! one-line description, the LEGACY (Set A) ripgrep/grep spelling(s) each native
//! flag aliases, and the process exit codes. This is the concrete answer to
//! "allow agents the most specificity in discovering it" — the two-set model is
//! machine-checkable, not just documented.
//!
//! The manifest is a static, deterministic document (the CLI surface is a
//! contract, not runtime state), emitted verbatim to stdout. There are two
//! lifecycle `verbs` (`index`, `status`); the search itself has no verb — it is
//! the bare `gist <pattern>` invocation, described under `search` below. Its
//! flag surface is a documented rg-compatible subset (`../ripgrep/args.zig`) —
//! broad but not every rg flag; unsupported flags fail loud — plus gist's own
//! additions (`--no-index`/`--index`/`--rank`). The full rg
//! flag list is a contract enumerated by the rgsuite differential-parity harness
//! rather than duplicated here; the manifest lists gist's native additions and
//! points at that coverage.

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");

/// The capability manifest. Kept in sync by hand with the unified engine's flag
/// parser (`../ripgrep/args.zig`) — the `--schema`/`--help` parity is asserted by
/// the CLI's own tests + the rgsuite differential-parity harness.
const manifest =
    \\{
    \\  "tool": "gist",
    \\  "version": "0.1.0",
    \\  "summary": "persistent trigram-indexed code locator; a drop-in for an agent's rg loop",
    \\  "verbs": {
    \\    "index": {
    \\      "summary": "build + persist the trigram index and freshness anchor (a mutating lifecycle action)",
    \\      "args": [],
    \\      "flags": []
    \\    },
    \\    "status": {
    \\      "summary": "read-only introspection: index presence, file/trigram/posting counts, on-disk size, build age, roots",
    \\      "args": [],
    \\      "flags": []
    \\    }
    \\  },
    \\  "search": {
    \\    "summary": "gist <pattern> [PATH...] [flags] — the canonical invocation: no verb, no setup. Live-scans the current tree with ripgrep's own default behavior (gitignore precedence, piped stdin, exit codes); when a fresh index covers the searched subtree it is used automatically to elide non-candidate reads, byte-identically to the pure walk.",
    \\    "args": [
    \\      {"name": "pattern", "type": "string", "required": true, "description": "the literal or RE2-style regex to find"},
    \\      {"name": "PATH...", "type": "string[]", "required": false, "description": "positional roots that scope the search (pruned before any read)"}
    \\    ],
    \\    "flag_surface": "documented rg-compatible subset (../ripgrep/args.zig) — broad but not every rg flag; unsupported flags fail loud, some are accepted-but-ignored. Measured by bench/rgsuite (441 mined rg-argv replays: 98.6% supported-surface parity, 4 known FAILs — see bench/rgsuite/README.md)",
    \\    "native_additions": [
    \\      {"native": "--rank", "type": "int?", "default": 20, "description": "gist's one shape rg can't express: the definition-first ranked view (RRF fusion; a symbol's definition outranks its call sites, codegen demoted). Optional =N caps the top-K. Requires an index."},
    \\      {"native": "--no-index", "type": "bool", "default": false, "description": "force the pure live walk (never consult the index)"},
    \\      {"native": "--index", "type": "bool", "default": false, "description": "force the index-accelerated read-elision path (default: auto-detect a fresh index)"}
    \\    ],
    \\    "alias": "gist rg [flags] <pattern> [PATH...] (an `alias rg=gist` drop-in shape) or gist search <pattern> [PATH...] (the habit-safe `search` verb) — both are the same engine addressed explicitly"
    \\  },
    \\  "output_stream": {"results": "stdout", "diagnostics": "stderr"},
    \\  "exit_codes": {"0": "ran (results on stdout, if any)", "1": "no match (ripgrep's own convention), or a usage/parse/unsupported-flag error (guidance on stderr)", "2": "usage error or a flag rg-parity can't honor by design (guidance on stderr)"}
    \\}
    \\
;

/// Emit the JSON capability manifest to stdout.
pub fn emit() void {
    corpus_mod.emitStdout(manifest);
}
