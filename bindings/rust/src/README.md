---
doc_radar:
  sentinels:
    - description: "substrate modules are mounted beside the regex face"
      file: bindings/rust/src/lib.rs
      contains: ["pub mod contract", "pub mod request", "pub mod runtime"]
---

# src

Two faces share this crate. The **regex** face is a `regex`-shaped API over a
buffer. The **substrate** face is the shared analytic base every product binding
imports (`gist`, `relate`, `blast`).

## Regex face

The seam is at the bottom and the `regex`-shaped API is at the top, and nothing
in between is allowed to skip a layer.

| File | What lives here |
|---|---|
| `sys.rs` | The C ABI, declared once. `extern "C"` signatures, the `repr(C)` structs, the flag bits, and the ABI version check. Nothing above this file mentions a raw pointer type. |
| `error.rs` | Regex-face `Error` and `Status`. The single place a negative status becomes a typed error, and the only place the thread-local fault slot is read. |
| `pool.rs` | The handles. A compiled C handle is single-threaded, so this hands out an exclusive lease of one and takes it back on drop. This is what makes `Regex` `Sync` without an `unsafe impl`. |
| `pattern.rs` | `Regex` and `RegexBuilder`, and the two engine calls everything is built on: `find_all` for the match sequence and `captures` for group detail. |
| `matches.rs` | `Match`, `Captures`, and the three iterators. Byte offsets, checked for UTF-8 boundary alignment before they can slice anything. |
| `replace.rs` | The `Replacer` trait, `$name` expansion, and the three replace verbs. |

## Substrate face

| Path | What lives here |
|---|---|
| `contract/` | Mirrored TOML constants, calibration, generated `schema.gen.rs` |
| `request.rs` | `SearchRequest` for the exact plane (shared with `gist`) |
| `runtime/` | Analytic ladder, row decode, subprocess / session transports, substrate `Error` |

The crate-root [`Error`](crate::Error) is the regex face. Analytic callers use
[`runtime::Error`](crate::runtime::Error).

## The one rule that shapes the whole thing

**The match sequence comes from `irregex_find_all`, never from a loop over
`irregex_captures`.** The engine decides what a sequence of matches is: whether
an empty match adjacent to the previous one counts, what happens at the end of
the buffer, how `word(true)` filtering interacts with resuming the scan. None of
that is derivable from a `find(from)` cursor, and every one of those rules is a
place a hand-rolled advance loop gets nullable patterns like `a*` and `\b`
wrong.

So `pattern.rs` asks `find_all` once for the authoritative spans, and only then,
per match and only when the pattern declares groups, asks `captures` for the
detail. The visible consequence is that `find_iter` is eager. It cannot be lazy;
the sequence is one answer.

`find_all` writes into a caller-sized window but reports how many matches the
*text* has, so a window that came up short sizes its own retry and there is
never more than a second pass. Sizing the first ask at the ceiling - a text of
`n` bytes cannot hold more than `n + 1` matches - would be a 16 MB span buffer
for a megabyte of text with four matches in it, so the first ask is a few
thousand spans and the count decides whether one more is needed. Nothing reads
past `out[..count.min(out.len())]`: the count is the text's, not the buffer's,
and past that point the buffer holds spans nobody wrote.

## Layers, and what each one is not allowed to do

- Nothing above `sys.rs` names a raw pointer or a status integer.
- Nothing above `error.rs` reads the fault slot. It holds *this thread's last
  failure*, so it has to be read immediately, before the caller makes another
  call; doing it anywhere else would attach the wrong detail or none.
- Nothing above `pool.rs` touches a handle without a lease. A lease is exclusive
  for its lifetime, which is the invariant every `// SAFETY:` comment in
  `pattern.rs` rests on.
- Nothing above `matches.rs` produces a `Match` from an unchecked span. Slicing
  a `str` at a non-boundary panics, so the check happens once, where the span
  arrives, and the offsets in a `Match` are boundary-aligned by construction.

## Panicking and checked verbs

Each search verb comes in two forms. `find` panics on an engine fault; `try_find`
returns it. The panicking form exists because that is what makes `re.find(text)`
return an `Option` and read like the crate a Rust programmer already knows, and
the faults reachable through it are an allocation failure - which Rust already
treats as fatal - and a capture arm the engine refused, which `Regex::groups`
reports without searching at all.
