//! gist search — the LEGACY ripgrep/grep-compatible alias layer (Set A).
//!
//! This is the secondary, muscle-memory surface: every flag `rg`/`grep` accept
//! keeps working with its familiar spelling, but each is a thin ALIAS onto
//! exactly one native option in `args.zig` (never a second competing behavior).
//! It exists so an agent's reflexive `-ln`, `-nC3`, `--count-matches`, `-t go`
//! just work, and so the ripgrep differential-parity harness keeps passing —
//! it is deliberately kept OFF the primary `--help`/`--schema` surface.
//!
//! Three failure disciplines carry over verbatim from the original grep parser:
//!   • **fail loud on a genuinely unknown flag** (a silent empty result is the
//!     worst agent failure) — the diagnostic lists the full supported surface;
//!   • **fail loud on a recognized-but-unsupportable flag** (`-P`, `-U`,
//!     `--vimgrep`, `--column`) with the specific reason + the `rg` fallback;
//!   • **accept as no-ops** the rg flags gist's fixed model / superset corpus
//!     already satisfy (`-n`, `--no-heading`, `--hidden`, `--no-ignore*`, …).

const std = @import("std");
const args = @import("args.zig");
const Sink = args.Sink;
const Long = args.Long;
const parseUsize = args.parseUsize;
const valErr = args.valErr;
const longVal = args.longVal;
const nextTok = args.nextTok;

pub const supported =
    "legacy (ripgrep/grep) aliases: -i -w -F -l -c -v -o -n -N -S -H -u -U -m N -A N -B N -C N " ++
    "-r <template> -t <lang> -g <glob> -e <pat> --  ·  long: --ignore-case --word-regexp " ++
    "--fixed-strings --files-with-matches --count --count-matches --invert-match --only-matching " ++
    "--no-line-number --smart-case --multiline --multiline-dotall --files --no-heading --color[=X] --replace=<template> " ++
    "--after/before/context=N --max-count=N --type=<lang> --glob=<glob> --regexp=<pat> " ++
    " ·  no-ops (gist already does): --hidden --no-ignore[-vcs/-parent/-dot] -u/--unrestricted --sort <key>" ++
    " ·  positional PATH args scope the search  ·  leading inline flags (?i)/(?s)/(?-u)/(?m) honored";

/// A flag gist *recognizes* but genuinely cannot honor (a different engine or
/// output model). Fail LOUD with the specific reason + the `rg` fallback — never
/// a silent wrong result, and never the generic "unknown flag" dump that leaves
/// an agent guessing whether it typo'd or hit a real limit.
fn unsupported(flag: []const u8, why: []const u8) bool {
    std.debug.print("flag {s} unsupported — {s}\n", .{ flag, why });
    return false;
}
const why_pcre = "gist runs a linear-time RE2-style engine (no backreferences or lookaround); use `rg -P <pat>` for a PCRE2 pattern";
const why_structured = "gist's --json emits path/line/text records; for ripgrep's own JSON/column/vimgrep framing use `rg --json`/`--vimgrep`/`--column`";

/// Decompose one `-xyz` short cluster (all short flags are legacy rg/grep
/// spellings). Each char is a boolean flag until the first *value* flag, which
/// consumes the cluster remainder (`-nC3` ⇒ n, C=3) or, if it sits at the
/// cluster end, the next argv token (`-C 3`). Returns false on an unknown short
/// flag or a missing value (fail loud).
pub fn shortCluster(sink: Sink, arg: []const u8, i: *usize, all: []const []const u8) !bool {
    var j: usize = 1; // past the leading '-'
    while (j < arg.len) : (j += 1) {
        const c = arg[j];
        // The value for a value-flag: the cluster tail if any, else next token.
        const takeVal = struct {
            fn get(a: []const u8, k: usize, idx: *usize, tokens: []const []const u8) ?[]const u8 {
                if (k + 1 < a.len) return a[k + 1 ..];
                return nextTok(idx, tokens);
            }
        }.get;
        switch (c) {
            // ── boolean flags (alias → native option) ──
            'i' => sink.opts.caseless = true,
            'w' => sink.opts.word = true,
            'F' => sink.opts.fixed = true,
            'l' => sink.opts.files_only = true, // → --show files
            'c' => sink.opts.count_only = true, // → --show count
            'v' => sink.opts.invert = true,
            'o' => sink.opts.only_matching = true,
            'N' => sink.opts.no_line_num = true,
            'S' => sink.opts.smart_case = true,
            // no-ops: gist's fixed `path:line:text` model already implies these.
            'n', 'H', 'R', 's' => {},
            // `-u`/`-uu` (`--unrestricted`): rg widens toward gist's corpus policy
            // (search `.gitignore`d + hidden files), which gist ALREADY does — a
            // no-op, not an error (README "Scope vs ripgrep").
            'u' => {},
            // `-U`/`--multiline`: match the whole file as one haystack (a match may
            // span `\n`; `^`/`$` anchor at every line boundary) — the native
            // whole-buffer engine (`Regex.bufMatch`). Honored, not an error.
            'U' => sink.opts.multiline = true,
            // recognized-but-unsupportable short flags: fail loud with the why.
            'P' => return unsupported("-P", why_pcre),
            // ── value flags: consume the rest of the cluster (or next token) ──
            'r' => {
                sink.opts.replace = takeVal(arg, j, i, all) orelse return valErr("-r");
                return true;
            },
            'A' => {
                sink.opts.after = parseUsize(takeVal(arg, j, i, all) orelse return valErr("-A")) orelse return valErr("-A");
                return true;
            },
            'B' => {
                sink.opts.before = parseUsize(takeVal(arg, j, i, all) orelse return valErr("-B")) orelse return valErr("-B");
                return true;
            },
            'C' => {
                const k = parseUsize(takeVal(arg, j, i, all) orelse return valErr("-C")) orelse return valErr("-C");
                sink.opts.before = k;
                sink.opts.after = k;
                return true;
            },
            'm' => {
                sink.opts.max_per_file = parseUsize(takeVal(arg, j, i, all) orelse return valErr("-m")) orelse return valErr("-m");
                return true;
            },
            't' => {
                if (!try sink.setType(takeVal(arg, j, i, all) orelse return valErr("-t"))) return false;
                return true;
            },
            'g' => {
                try sink.addGlob(takeVal(arg, j, i, all) orelse return valErr("-g"));
                return true;
            },
            'e' => {
                sink.setPattern(takeVal(arg, j, i, all) orelse return valErr("-e"));
                return true;
            },
            else => {
                std.debug.print("unknown flag '-{c}' in '{s}' — {s}\n", .{ c, arg, supported });
                return false;
            },
        }
    }
    return true;
}

/// Handle a `--long` flag the NATIVE layer didn't recognize: a legacy rg/grep
/// spelling (aliased onto a native option), a corpus-policy no-op, an
/// unsupportable flag (fail loud), or a genuinely unknown flag (fail loud). `lf`
/// is the pre-split name/value; `arg` is the raw token for diagnostics.
pub fn longAlias(sink: Sink, arg: []const u8, lf: Long, i: *usize, all: []const []const u8) !bool {
    const eq = std.mem.eql;
    const n = lf.name;
    if (eq(u8, n, "word-regexp")) sink.opts.word = true else if (eq(u8, n, "fixed-strings")) sink.opts.fixed = true else if (eq(u8, n, "files-with-matches")) sink.opts.files_only = true else if (eq(u8, n, "count")) sink.opts.count_only = true else if (eq(u8, n, "count-matches")) sink.opts.count_matches = true else if (eq(u8, n, "invert-match")) sink.opts.invert = true else if (eq(u8, n, "no-line-number")) sink.opts.no_line_num = true else if (eq(u8, n, "line-number") or eq(u8, n, "no-heading") or eq(u8, n, "heading") or eq(u8, n, "with-filename") or eq(u8, n, "no-filename") or eq(u8, n, "recursive") or eq(u8, n, "case-sensitive") or eq(u8, n, "color") or
        // Corpus-policy no-ops: rg flags widening its default corpus toward what
        // gist ALREADY searches — `.gitignore`d files, hidden dotfiles (README
        // "Scope vs ripgrep"). gist's corpus is a superset, so these ask for what
        // it already does. `--color[=X]` swallows an X.
        eq(u8, n, "hidden") or eq(u8, n, "no-ignore") or eq(u8, n, "no-ignore-vcs") or eq(u8, n, "no-ignore-parent") or eq(u8, n, "no-ignore-dot") or eq(u8, n, "no-ignore-global") or eq(u8, n, "no-ignore-files") or eq(u8, n, "unrestricted") or eq(u8, n, "one-file-system") or eq(u8, n, "stats"))
    {
        if (lf.val == null and eq(u8, n, "color")) _ = nextTok(i, all);
    } else if (eq(u8, n, "sort") or eq(u8, n, "sortr")) {
        // gist emits results **path-ascending** already (a stable, deterministic
        // order — see runGrep's `cmpBlocks` sort). `--sort path` is exactly that,
        // so it's a no-op; other keys can't be honored from the index, but path
        // order is the overwhelmingly common request. Swallow the value, go on.
        _ = longVal(lf.val, i, all) orelse return valErr("--sort");
    } else if (eq(u8, n, "pcre2") or eq(u8, n, "auto-hybrid-regex")) {
        return unsupported(arg, why_pcre);
    } else if (eq(u8, n, "vimgrep") or eq(u8, n, "column")) {
        return unsupported(arg, why_structured);
    } else if (eq(u8, n, "after-context")) {
        sink.opts.after = parseUsize(longVal(lf.val, i, all) orelse return valErr("--after-context")) orelse return valErr("--after-context");
    } else if (eq(u8, n, "before-context")) {
        sink.opts.before = parseUsize(longVal(lf.val, i, all) orelse return valErr("--before-context")) orelse return valErr("--before-context");
    } else if (eq(u8, n, "max-count")) {
        sink.opts.max_per_file = parseUsize(longVal(lf.val, i, all) orelse return valErr("--max-count")) orelse return valErr("--max-count");
    } else if (eq(u8, n, "type")) {
        if (!try sink.setType(longVal(lf.val, i, all) orelse return valErr("--type"))) return false;
    } else if (eq(u8, n, "regexp")) {
        sink.setPattern(longVal(lf.val, i, all) orelse return valErr("--regexp"));
    } else {
        std.debug.print("unknown flag '{s}' — {s}\n", .{ arg, supported });
        return false;
    }
    return true;
}

/// Strip a leading GLOBAL inline-flag group `(?flags)` (rg syntax), applying it
/// to `opts`, and return the pattern with the group removed (a borrowed
/// sub-slice, no alloc). rg lets a pattern begin with `(?i)`, `(?-u)`, `(?im)`,
/// … and an agent pastes them reflexively; rejecting the whole pattern forced a
/// fallback to rg. Flag map — each honored soundly or a documented no-op:
///   • `i` → caseless ASCII fold; `-i` clears.
///   • `m` → no-op: gist's `^`/`$` are line anchors in BOTH modes (per-line by
///     default, every line boundary under `-U`) — always rg's `(?m)` behavior.
///   • `s` → dotall: `.` also matches `\n` (takes effect with `-U`; inert per-line,
///     exactly as rg — a line never carries a `\n`). `(?-s)` clears it.
///   • `u`/`U` (and any `-…` form) → no-op: gist is byte-oriented (== rg `(?-u)`).
/// Rejected LOUD (returns null after guidance — never a silent mismatch):
///   • `x` extended/whitespace-insensitive — unsupported by the parser.
/// A non-flag `(?` — `(?:…)`, `(?=…)`, `(?<name>…)` — is left for the compiler.
pub fn applyInlineFlags(pat: []const u8, opts: *args.Options) ?[]const u8 {
    if (!std.mem.startsWith(u8, pat, "(?")) return pat;
    var negate = false;
    var j: usize = 2;
    while (j < pat.len) : (j += 1) {
        switch (pat[j]) {
            ')' => return pat[j + 1 ..], // consumed a handled global flag group
            ':' => return pat, // `(?flags:…)` scoped group — leave to the compiler
            '-' => negate = true,
            'i' => opts.caseless = !negate,
            'm', 'u', 'U' => {}, // no-ops (see doc)
            's' => opts.dotall = !negate, // dotall: `.` matches `\n` (with -U); `(?-s)` clears
            'x' => {
                if (negate) continue; // `(?-x)` turns OFF ⇒ already gist's default
                std.debug.print("inline flag '(?x…)' unsupported — gist has no extended/whitespace-insensitive mode (drop it, or use rg)\n", .{});
                return null;
            },
            else => return pat, // not a recognized flag char ⇒ not a flag group
        }
    }
    return pat; // ran off the end with no ')' ⇒ let the compiler report it
}

/// A `--replace` template may only reference the whole match (`$0`, `${0}`,
/// `$&`) or an escaped literal `$` (`$$`), because gist's span engine tracks the
/// whole-match extent but not per-group captures. A numbered/named group ref
/// (`$1`, `${2}`, …) is rejected LOUD here so the failure surfaces at parse time,
/// not as a silently dropped substitution mid-stream.
pub fn validReplaceTemplate(t: []const u8) bool {
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '$') continue;
        if (i + 1 >= t.len) return true; // trailing '$' is a literal
        const n = t[i + 1];
        if (n == '$' or n == '&' or n == '0') {
            i += 1;
            continue;
        }
        if (n == '{') {
            const close = std.mem.indexOfScalarPos(u8, t, i + 2, '}') orelse {
                std.debug.print("bad --replace template: unterminated '${{' in \"{s}\"\n", .{t});
                return false;
            };
            const name = t[i + 2 .. close];
            if (std.mem.eql(u8, name, "0")) {
                i = close;
                continue;
            }
            std.debug.print("--replace group reference \"${{{s}}}\" unsupported — gist tracks the whole match only; use $0/${{0}}/$& (or rg for capture-group rewrites)\n", .{name});
            return false;
        }
        std.debug.print("--replace group reference \"${c}\" unsupported — gist tracks the whole match only; use $0/${{0}}/$& (or rg for capture-group rewrites)\n", .{n});
        return false;
    }
    return true;
}
