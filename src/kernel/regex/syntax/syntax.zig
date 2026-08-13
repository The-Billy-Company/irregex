//! irregex — regex *syntax*: byte classes, the AST, the compiled NFA instruction,
//! and a recursive-descent parser for the supported subset. The sound AST
//! analyses that feed the prefilter (required-literal extraction, anchored-start
//! detection) live in `analysis.zig`; the execution half (Thompson NFA compile +
//! Pike simulation) lives in `../linear/`. Both import this module.
//!
//! This file is the plane's front door and nothing else: one declaration per
//! exported name, so every consumer keeps importing `syntax/syntax.zig` while the
//! implementation sits in five files behind it — `tree.zig` (the vocabulary:
//! `ByteSet`, `Node`, `State`, `ParseError`), `assertion.zig` (the word-assertion
//! truth table), `scalars.zig` (scalar-range accumulation + the `-i` fold),
//! `escape.zig` (backslash escapes + POSIX tables), `bracket.zig` (`[...]`
//! bodies), and `parser.zig` (the cursor + the recursive descent).
//!
//! Supported (ASCII / byte-oriented, matching ripgrep's `(?-u)` mode):
//!   literals · `.` (any byte but '\n') · `[...]` / `[^...]` with `a-z` ranges
//!   and POSIX bracket classes `[[:alpha:]]` … `[[:^space:]]` (ASCII sets, the
//!   `(?-u)` twins rg accepts) · `*` `+` `?` · `{n}` `{n,}` `{n,m}` counted
//!   repetition · `|` · `(...)` grouping · line anchors `^` `$` · haystack
//!   anchors `\A` `\z` (start/end of haystack — the line in the per-line
//!   default, the whole buffer under multiline) · the six word assertions `\b`
//!   `\B` `\<` `\>` and rust-regex's braced spellings `\b{start}` `\b{end}`
//!   `\b{start-half}` `\b{end-half}` (see `Word`; ASCII here is the
//!   `[0-9A-Za-z_]` class — exactly rg `--no-unicode`) · escapes
//!   `\t \n \r \f \v \a \xNN \x{H..H} \d \D \w \W \s \S` plus any escaped
//!   ASCII punctuation (`\. \* \\ \/ \-` … → the literal byte).
//! rg-parity rejections (BadPattern, never a silent literal): `\0`–`\9`
//! (backreference syntax — unsupported in a linear-time engine; NUL is `\x00`),
//! any other escaped ASCII letter or digit (`\q`, `\e`, `\Z`, … — rg's
//! "unrecognized escape sequence"), and any assertion escape inside a class
//! (`[\b]`, `[\A]`, `[\z]`, `[\<]`, `[\>]` — rg's "invalid escape sequence
//! found in character class").
//! Like rust-regex, an unescaped `{` must begin a valid count (else BadPattern;
//! a literal brace is `\{`); a stray `}` is literal.

const tree = @import("tree.zig");
const assertion = @import("assertion.zig");
const scalars = @import("scalars.zig");

// ── the vocabulary every downstream stage is written against (`tree.zig`) ──
pub const ByteSet = tree.ByteSet;
pub const Node = tree.Node;
pub const NamedCap = tree.NamedCap;
pub const State = tree.State;
pub const ParseError = tree.ParseError;

// ── the word-assertion family, as a truth table (`assertion.zig`) ──
pub const Word = assertion.Word;
pub const Sides = assertion.Sides;
pub const mask = assertion.mask;

// ── scalar ranges: parse-time accumulation and the `-i` fold (`scalars.zig`) ──
pub const ScalarSet = scalars.ScalarSet;
pub const foldCaseAst = scalars.foldCaseAst;
pub const stripCpAst = scalars.stripCpAst;
pub const wordBoundedAst = scalars.wordBoundedAst;

// ── the parser (`parser.zig`; class/escape bodies in `bracket.zig`/`escape.zig`) ──
pub const Parser = @import("parser.zig").Parser;

// ── the leading `(?flags)` directive, read as options (`directive.zig`) ──
// Not a production of the parser above: a head directive is a statement about
// how to COMPILE the pattern, so it is read before parsing rather than parsed.
pub const Directive = @import("directive.zig").Directive;
pub const Preamble = @import("directive.zig").Preamble;
pub const preamble = @import("directive.zig").preamble;
