Warm resident session eligibility for `-q`/`--quiet` and `-m N`/`--max-count N`,
byte-identical to cold. `-q` becomes an existence early-halt: the daemon walks
the corpus only until the first match, answers a single matched bit, and the
client prints nothing and sets the exit code (0 found / 1 not) — the no-match
hint stays silent, exactly as cold's quiet path. `-m N` caps matching lines per
file (per-file reset) across `-c`, `-l`, and the default line emit, mirroring
rg's `-m0` = match-nothing (exit 1) at the session boundary. The v2 query flags
byte now carries `quiet` (bit 6) and `max_count` (bit 7) live alongside
`smart_case`/`word`; `max_count` is the first flag with a payload — a `u64 LE`
cap written immediately after the flags byte — and `decodeQuery` fails closed on
a truncated cap (BadFrame → decline → cold). The engine branches once at the top
of each face (a comptime-generic count cap; the warm line renderer routes the cap
through cold's own `Emitter`), leaving the uncapped hot loops byte-for-byte
unchanged. Python `SearchRequest.max_count` becomes `int | None` so the falsy
`-m0` is distinguishable from unset. Both flags are UDS- and FFI-eligible: the
size-checked `irregex_search` options contract carries quiet plus the
`u64` per-file cap. Smart-case is
FFI-eligible too: C carries the raw bit and Zig's `effectiveIgnoreCase` remains
the sole Unicode uppercase authority. Explicit path scopes also route through
FFI's existing root-array ABI; Python bounds and keys handles by `(cwd, roots)`
so one request can never reuse another scope's corpus. Explicit Unicode/ASCII
mode is FFI-eligible as well, lowered into the shared `CompiledQuery` rather
than reimplemented by the binding. `engine="auto"` now tries FFI for
linear-compatible patterns and treats `IRREGEX_STALE` as the existing signal
to fall through to cold PCRE2. Invert-match (`-v`) is now FFI-eligible: the
resident stream scans every live document, selects only lines with zero spans,
and keeps quiet/max-count/files/count semantics byte-identical to cold. Context
windows are FFI-eligible too, with explicit match/context record kinds. C ABI 1
starts with one coherent options and match shape; its Zig layout
lives in `runtime/ffi/contract.zig`, separate from session execution. The UDS
protocol version is unchanged (bits 6/7 were reserved).
