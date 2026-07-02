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
//! contract, not runtime state), emitted verbatim to stdout. The internal `rg`
//! differential-parity path is deliberately absent — it is harness plumbing, not
//! a capability an agent should reach for.

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");

/// The capability manifest. Kept in sync by hand with `search/args.zig` (native
/// flags) and `search/compat.zig` (legacy aliases) — the `--schema`/`--help`
/// parity is asserted by the CLI's own tests + the two-set doc in the README.
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
    \\    },
    \\    "search": {
    \\      "summary": "the one search verb; pattern is auto-detected literal-or-regex, output shape is a flag",
    \\      "args": [
    \\        {"name": "pattern", "type": "string", "required": true, "description": "the literal or RE2-style regex to find"},
    \\        {"name": "PATH...", "type": "string[]", "required": false, "description": "positional roots that scope the search (pruned before any read)"}
    \\      ],
    \\      "flags": [
    \\        {"native": "--show", "type": "enum(lines|files|count|ranked)", "default": "lines", "legacy_aliases": ["-l (files)", "-c (count)", "--files-with-matches", "--count"], "description": "output shape"},
    \\        {"native": "--rank", "type": "int?", "default": 20, "legacy_aliases": [], "description": "shorthand for --show ranked; optional =N caps the top-K (definition-first RRF)"},
    \\        {"native": "--lang", "type": "string", "default": null, "legacy_aliases": ["-t", "--type"], "description": "scope by language (go/py/rust/ts/js/swift/zig/sql/proto/...)"},
    \\        {"native": "--glob", "type": "string", "default": null, "legacy_aliases": ["-g"], "description": "scope by path glob; a leading ! excludes"},
    \\        {"native": "--word", "type": "bool", "default": false, "legacy_aliases": ["-w", "--word-regexp"], "description": "match on word boundaries"},
    \\        {"native": "--fixed", "type": "bool", "default": false, "legacy_aliases": ["-F", "--fixed-strings"], "description": "treat the pattern as a literal string"},
    \\        {"native": "--ignore-case", "type": "bool", "default": false, "legacy_aliases": ["-i"], "description": "case-insensitive (ASCII fold)"},
    \\        {"native": "--smart-case", "type": "bool", "default": false, "legacy_aliases": ["-S"], "description": "case-insensitive iff the pattern has no uppercase"},
    \\        {"native": "--invert", "type": "bool", "default": false, "legacy_aliases": ["-v", "--invert-match"], "description": "emit non-matching lines"},
    \\        {"native": "--before", "type": "int", "default": 0, "legacy_aliases": ["-B"], "description": "context lines before each match"},
    \\        {"native": "--after", "type": "int", "default": 0, "legacy_aliases": ["-A"], "description": "context lines after each match"},
    \\        {"native": "--context", "type": "int", "default": 0, "legacy_aliases": ["-C"], "description": "context lines on both sides"},
    \\        {"native": "--limit", "type": "int", "default": 0, "legacy_aliases": ["-m", "--max-count"], "description": "cap rows per file (0 = unbounded)"},
    \\        {"native": "--spans", "type": "bool", "default": false, "legacy_aliases": ["--count-matches"], "description": "with --show count, count match spans instead of lines"},
    \\        {"native": "--replace", "type": "string", "default": null, "legacy_aliases": ["-r"], "description": "rewrite each match ($0/${0}/$& = whole match; $$ = literal $)"},
    \\        {"native": "--only-matching", "type": "bool", "default": false, "legacy_aliases": ["-o"], "description": "emit each match span, not the whole line"},
    \\        {"native": "--live", "type": "bool", "default": false, "legacy_aliases": [], "description": "skip the index, scan the live tree fresh"},
    \\        {"native": "--json", "type": "bool", "default": false, "legacy_aliases": [], "description": "structured records instead of path:line:text"},
    \\        {"native": "--pattern", "type": "string", "default": null, "legacy_aliases": ["-e"], "description": "explicit pattern (leading-dash safe)"},
    \\        {"native": "--files", "type": "bool", "default": false, "legacy_aliases": [], "description": "list corpus files (no pattern, no read)"}
    \\      ]
    \\    }
    \\  },
    \\  "output_stream": {"results": "stdout", "diagnostics": "stderr"},
    \\  "exit_codes": {"0": "ran (results, if any, on stdout)", "1": "usage / parse error / unsupported flag (guidance on stderr)"}
    \\}
    \\
;

/// Emit the JSON capability manifest to stdout.
pub fn emit() void {
    corpus_mod.emitStdout(manifest);
}
