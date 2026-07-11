//! gist `rg` — the ripgrep-compatible CLI flag surface (parsing only).
//!
//! Split from `run.zig` (the walk + match + emit shell) the same way the grep
//! verb's `args.zig` splits from its `emit.zig`. This module is now a thin
//! facade over the two halves that grew out of it: the resolved option schema
//! (`opts.zig` — `Opts`, `Filter`, `Parsed`, `die`) and the argv → `Opts`
//! lowering (`flags.zig` — `parseArgv`, `looksLikeRegex`). It re-exports every
//! public name so `args.Opts` / `args.die` / `args.parseArgv` call sites across
//! the ripgrep engine are unchanged. It implements ripgrep's DEFAULT flag
//! semantics and FAILS LOUD (exit 2) on any flag gist can't honor by design
//! (`--json`, `-U`, `-P`, `--column`, `--binary`, …), so the differential
//! harness scores those N/A rather than silently wrong.

const opts = @import("opts.zig");
const flags = @import("flags.zig");

pub const Filename = opts.Filename;
pub const ColorChoice = opts.ColorChoice;
pub const Filter = opts.Filter;
pub const Opts = opts.Opts;
pub const Parsed = opts.Parsed;
pub const die = opts.die;

pub const looksLikeRegex = flags.looksLikeRegex;
pub const parseArgv = flags.parseArgv;
