//! gist — PCRE2 backend (the opt-in `-P`/`--pcre2` engine).
//!
//! gist's DEFAULT engine (`core.zig`) is a linear-time RE2/Pike matcher: no
//! backtracking, no catastrophic blowup, and — by construction — no lookaround
//! or backreferences. That is the right default (it is what makes gist safe to
//! run over an adversarial tree), but it leaves a real functional gap ripgrep
//! closes with `-P`: PCRE-only constructs (`(?=…)`, `(?<=…)`, `\1`, `(?P=name)`).
//!
//! This module is the SECOND, opt-in backend that closes that gap — the same
//! engine family ripgrep's `-P` uses (PCRE2 with JIT). It presents the exact
//! surface `matcher.zig` needs — `lineMatch` / `matchSpan` / `docMatch` /
//! `bufMatch`, a required-literal for the trigram prefilter, and per-thread
//! scratch — so the whole `exec/cold` output layer consumes it through
//! the `Matcher` seam without knowing which engine produced a span.
//!
//! This file is the STABLE module entry: it re-exports the exact
//! `Pcre`/`Options`/`CompileError`/`Span` surface `matcher.zig` imports, while
//! the implementation lives under `pcre2/` (`ffi.zig` — the vendored PCRE2 10.47
//! C ABI; `engine.zig` — the compiled-program + per-thread-scratch wrapper;
//! `literal.zig` — sound required-literal extraction). See `pcre2/README.md`.

const engine = @import("engine.zig");

/// A byte span `[start, end)` of one match — identical to the linear engine's
/// `Regex.Span`, so the shared output layer needs one span type across engines.
pub const Span = engine.Span;

/// Compile-time engine knobs, mirroring `Regex.Options` where they overlap so a
/// single `Matcher.Options` can drive either backend. `unicode` selects PCRE2's
/// Unicode property/character-class semantics (rg's `-P` default); when off the
/// engine matches raw bytes with ASCII rules, matching gist's linear default.
pub const Options = engine.Options;

/// The error surface the caller (`run.zig`) maps onto its fail-loud / cold
/// fallback contract. `Unsupported` covers "not built / not available" so the
/// CLI degrades exactly as it does for any construct gist declines.
pub const CompileError = engine.CompileError;

/// A compiled PCRE2 program plus the derived required-literal the trigram index
/// prunes by. Immutable after `compileOpts`; the only per-query mutable state is
/// the caller-owned `Sim`/`SpanSim` scratch, so one `Pcre` is shared across
/// workers (PCRE2 match data lives per-thread inside the scratch).
pub const Pcre = engine.Pcre;

/// The ceilings a caller may put on one search (`mark.Limits`), and what this
/// arm reports when one is reached. `null`/all-null is the arm's own defaults,
/// so a host that names nothing gets exactly today's engine.
///
/// The three verbs are one fact read three ways: `ceilingHit` says WHICH
/// ceiling (the `munch.Because` shape — a small enumerated reason beside the
/// answer), `budgetVerdict` turns it into the `error.BudgetExceeded` a host can
/// `try`, and `fault.last()` carries the incident the C seam pulls. All three
/// are silent unless the caller actually asked to be stopped.
pub const Limits = engine.Limits;
pub const Ceiling = engine.Ceiling;
pub const BudgetError = engine.BudgetError;
pub const ceilingHit = engine.ceilingHit;
pub const budgetVerdict = engine.budgetVerdict;

/// The most recent compile diagnostic for this thread ("" if none) — the useful
/// message surface behind a `BadPattern`, sitting beside the frozen error set.
pub const lastError = engine.lastError;

/// Where in the pattern that diagnostic was detected — PCRE2's own
/// `erroroffset`. Read only beside `lastError`; on its own it means nothing.
pub const lastErrorOffset = engine.lastErrorOffset;

/// Sticky match-time error surface: `matchError` returns the latched code (0 =
/// none), `clearMatchError` resets it before a run, `matchErrorMessage` renders
/// it. A resource-limit/fault during matching (catastrophic backtracking, JIT
/// stack overflow) is what ripgrep exits 2 on; the CLI reads this after the
/// search and mirrors that exit instead of the silent no-match `matchSpan` gives.
pub const matchError = engine.matchError;
pub const clearMatchError = engine.clearMatchError;
pub const matchErrorMessage = engine.matchErrorMessage;

test {
    _ = engine;
    _ = @import("literal.zig");
    _ = @import("captures.zig");
    _ = @import("shadow.zig");
}
