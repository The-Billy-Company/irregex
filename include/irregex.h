/* irregex — a regex over a buffer you already hold.
 *
 * This is the engine's own C ABI, and it is deliberately small: compile a
 * pattern, then ask is_match / find_all / captures about bytes in your
 * process. There is no corpus here — no session, no walk, no index, no
 * freshness. A host that wants those links libgist, whose header is gist.h and
 * whose symbols are gist_*; a host that just wants a regex links this and gets
 * nothing it did not ask for.
 *
 * Every entry returns a status instead of aborting, so a bad pattern can never
 * terminate the host. On a negative status, irregex_last_fault gives the
 * per-incident detail behind it.
 *
 * This header is also the SUBSTRATE the rest of the ecosystem speaks:
 * librelate, libgist, and libblast each link this library and return these
 * status codes, this fault struct, these pattern flags, and the same row
 * cursor walked by the irregex_rows_* symbols below. A host that links two of
 * them reads one vocabulary, not two spellings of the same word. */
#ifndef IRREGEX_H
#define IRREGEX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── versions ────────────────────────────────────────────────────── */

/* C-ABI version for THIS library; bump on any breaking change so a consumer
 * can reject a mismatched shared object. Additive symbols do not bump it.
 * Independent of libgist's session-ABI version — they are separate axes. */
uint32_t irregex_abi_version(void);

/* The engine semantic version (e.g. "0.3.0"), NUL-terminated, static-lifetime,
 * never NULL. Lets a binding version-gate the library it loaded. */
const char *irregex_version(void);

/* The vendored PCRE2 version the IRREGEX_PCRE arm runs on. "Which regex
 * grammar do I have" is two numbers; this is the second. */
const char *irregex_pcre2_version(void);

/* ── the shared status vocabulary ────────────────────────────────── */

/* Non-negative = success (IRREGEX_OK ran with no match, IRREGEX_MATCH had at
 * least one); negative = the call did not produce a result. IRREGEX_STALE is
 * the one negative that is NOT an error: a tier declined and the caller should
 * answer through its fallback, unchanged. */
#define IRREGEX_OK 0
#define IRREGEX_MATCH 1
#define IRREGEX_STALE (-1)
#define IRREGEX_OOM (-2)
#define IRREGEX_OPEN_FAILED (-3)
#define IRREGEX_INVALID (-4)

/* A static, NUL-terminated human message for a status code. For a log line,
 * never for a decision — the typed code is the contract. Pure reader: it does
 * not disturb the fault slot, so it is safe to call before irregex_last_fault. */
const char *irregex_status_message(int32_t code);

/* ── the fault detail ────────────────────────────────────────────── */

/* Which ruler `irregex_fault.at` is measured in. One offset, two possible
 * subjects: a byte in the file being read, or a byte in the pattern being
 * compiled. It used to be inferable rather than stated -- `at` meant a file
 * offset unless `path` came back NULL -- so every caller wrote the same
 * three-clause conjunction, and a missed clause points a caret at the wrong
 * string. IRREGEX_AT_NONE is 0 because byte 0 is a real offset: absence cannot
 * be spelled by `at` itself, so a reader that only wants "is there a position at
 * all" still gets it from a zero test.
 *
 * This field is the ABI-1 `has_at` boolean widened in place -- same offset, same
 * width -- so struct_size cannot catch the difference and a v1 header over a v2
 * library would read a pattern offset as a file one. That is what
 * irregex_abi_version returning 2 is for; gate on it, not on the size. */
#define IRREGEX_AT_NONE 0    /* no offset: about the file/allocation as a whole */
#define IRREGEX_AT_FILE 1    /* a byte offset within `path`                     */
#define IRREGEX_AT_PATTERN 2 /* a byte offset within the compiled PATTERN       */

/* Detail for the LAST failing call on THIS thread, filled by
 * irregex_last_fault. Set struct_size yourself before the call; the layout is
 * append-only, so an unknown size fails closed rather than misreading. */
typedef struct {
  uint32_t struct_size;
  int32_t status;   /* the status this fault crossed the seam as  */
  int32_t at_space; /* IRREGEX_AT_*: which ruler `at` is measured in, and zero
                     * when there is no offset at all             */
  const char *name;      /* fault name ("Corrupt"), static, never NULL */
  const uint8_t *path;   /* file it was about, or NULL; NOT NUL-term'd */
  size_t path_len;
  uint64_t at; /* the offset, in the space at_space names; 0 and meaningless
                * when that is IRREGEX_AT_NONE */
} irregex_fault;

/* Fill *out with this thread's last fault. Returns IRREGEX_MATCH when one was
 * written, IRREGEX_OK when the thread has none, or IRREGEX_INVALID for a NULL
 * or wrongly-sized out. IRREGEX_OK still writes: every field is cleared and
 * `name` becomes "" (never NULL), so the struct is meaningful either way and a
 * host cannot end up trusting its own uninitialized stack.
 *
 * A non-OK status from a WORK call does not imply a detail exists: an argument
 * guard has nothing to add over irregex_status_message, and a declinature is
 * not a fault at all. IRREGEX_STALE in particular installs nothing, so do not
 * follow one with a read -- the slot is per-thread and never consumed, so what
 * you would get back is an EARLIER call's fault, which looks exactly like a
 * fresh one. Decide a declinature from the status code and stop there.
 *
 * Reading does not consume -- ask twice, or ask either side of
 * irregex_status_message, and get the same answer. What clears the slot is this
 * thread's next WORK call, which opens a fresh window so that asking after a
 * SUCCESS hands you nothing rather than an older failure. So the two facts are
 * about different things and it is worth not conflating them: reads are free
 * and repeatable, and the deadline is the next call that does work. The
 * borrowed `path` points into the slot and expires with it. */
int32_t irregex_last_fault(irregex_fault *out);

/* ── pattern semantics ───────────────────────────────────────────── */

/* What a pattern MEANS. Shared with libgist, which adds its behavioral bits
 * (quiet, invert, max_count) in the gaps at 3, 4 and 7 — one numbering across
 * the ecosystem, so "ignore case" has a single definition. Any bit outside
 * this set makes irregex_compile return IRREGEX_INVALID: an unknown flag is
 * never silently dropped. */
#define IRREGEX_FIXED (1u << 0)       /* -F: fixed string, not a regex     */
#define IRREGEX_IGNORE_CASE (1u << 1) /* -i: case-insensitive              */
#define IRREGEX_WORD (1u << 2)        /* -w: word-bounded matches only     */
#define IRREGEX_SMART_CASE (1u << 5)  /* -S: fold iff pattern has no caps  */
#define IRREGEX_NO_UNICODE (1u << 6)  /* ASCII classes/fold/boundaries     */
#define IRREGEX_PCRE (1u << 8)        /* -P: PCRE2 grammar (lookaround...) */

/* A borrowed UTF-8 span. NOT NUL-terminated; `len` is authoritative. Shared
 * vocabulary: it is how the row protocol below carries every string, and how
 * irregex_group_name hands one back, so a host writes one reader for both. */
typedef struct {
  const uint8_t *ptr;
  size_t len;
} irregex_text;

/* ── the regex plane ─────────────────────────────────────────────── */

/* A compiled pattern. Opaque, and SINGLE-THREADED: it owns the scratch its
 * finds run in, so two threads sharing one handle corrupt a match rather than
 * race a counter. Compile one per thread — the compile is pure. */
typedef struct irregex_regex irregex_regex;

/* One byte range [start, end) in the searched text, or {-1, -1} for a capture
 * group the match did not enter. Signed because absence is a real answer:
 * "(a)|(b)" always leaves one of the two unset. */
typedef struct {
  int64_t start;
  int64_t end;
} irregex_span;

/* Compile pattern[0..len] under `flags` and write the handle to *out.
 * IRREGEX_OK on success; negative on failure, with the reason available from
 * irregex_last_fault. IRREGEX_SMART_CASE resolves here, against the same
 * has-uppercase predicate the CLI's -S runs. (pattern NULL with len 0 is the
 * empty pattern, which compiles — a language whose empty string carries no data
 * pointer hands that in without meaning anything by it. NULL with len != 0 is
 * IRREGEX_INVALID.)
 *
 * A REFUSED PATTERN answers with the one thing you can act on -- whether a
 * slower engine here would take it -- and it answers on the RETURN VALUE, so
 * you never have to reach for the fault to find out what to do next:
 *
 *   IRREGEX_STALE   - the linear grammar cannot express it (lookaround, a
 *                     backreference, an atomic group) but PCRE2 can. Recompile
 *                     the same pattern with IRREGEX_PCRE and it succeeds. This
 *                     is a DECLINATURE, not a failure: *out is untouched, and
 *                     irregex_last_fault stays silent, because a tier that
 *                     stepped aside has nothing to confess.
 *   IRREGEX_INVALID - nothing here accepts it. irregex_last_fault names it
 *                     "BadPattern", at_space is IRREGEX_AT_PATTERN, and `at`
 *                     marks the byte in THE PATTERN where the refusal was
 *                     detected (path is NULL: no file is involved). IRREGEX_PCRE
 *                     will not rescue it. The name is "Unsupported" instead, with
 *                     no position, in the one case where there was no PCRE2 to
 *                     escalate to at all -- a build without it. A tier that does
 *                     not exist has refused, which is when the declinature above
 *                     becomes this fault.
 *
 * Which one you get is decided by asking PCRE2, not by inspecting the pattern,
 * so it tracks whatever the linked PCRE2 actually supports rather than a list
 * that would drift from it. */
int32_t irregex_compile(const uint8_t *pattern, size_t len, uint32_t flags,
                        irregex_regex **out);

/* Release a handle from irregex_compile. Leaves the fault slot alone, so you
 * can still read the detail that made you clean up. */
void irregex_free(irregex_regex *re);

/* Whether text[0..len] holds a match: IRREGEX_MATCH yes, IRREGEX_OK no,
 * negative on error. The cheapest question here — the same walk find_all runs,
 * stopped at the first span rather than materializing the rest, so the two
 * always agree about the same text. (text NULL with len 0 is the empty text, a
 * legitimate question; NULL with len != 0 is IRREGEX_INVALID.)
 *
 * The buffer is ONE unit: ^ \A match at offset 0 and $ \z at len, and an
 * interior newline is an ordinary byte, not a boundary. There is no corpus
 * behind this plane, so a multi-line buffer is a long line — pass lines
 * separately if you want per-line anchors. */
int32_t irregex_is_match(irregex_regex *re, const uint8_t *text, size_t len);

/* Write the matches in text[0..len] into out[0..cap] and their count into
 * *written. IRREGEX_MATCH when the TEXT HAS at least one, IRREGEX_OK when it
 * holds none, negative on error. The status is about the text, never about the
 * window: a count query (cap 0) writes nothing and still returns MATCH.
 *
 * The whole text is one unit, so the iteration rules — empty matches,
 * adjacency, -w filtering — are the engine's own, identical to the spans the
 * same pattern produces in `gist --json`. That is why there is no
 * find(from)-style cursor: a hand-rolled loop is exactly where those rules get
 * re-invented and the nullable patterns come out wrong.
 *
 * "The whole text" is the unit gist calls a line, and gist's lines carry their
 * terminator. So a nullable pattern reports one more empty span over "abc\n"
 * than over "abc" — the trailing empty match is suppressed at the end of the
 * buffer, and the newline moves where that end is. Anyone diffing these spans
 * against gist's must hand this verb the terminator too.
 *
 * `cap` is a window over the answer, not a limit on the search: at most cap
 * spans are written, and *written reports how many the TEXT HAS -- so a short
 * window sizes its own retry, exactly as irregex_captures does for a short group
 * buffer. The two are siblings and used to disagree here, which cost every
 * caller the same grow-and-rescan loop: with a saturating count, "did I get
 * everything?" was undecidable, since written == cap is equally a full window
 * and an exact fit. Size cap at len + 1 to be sure of one pass, or pass cap 0
 * with a NULL out to ask only how many there are. */
int32_t irregex_find_all(irregex_regex *re, const uint8_t *text, size_t len,
                         irregex_span *out, size_t cap, size_t *written);

/* Write the group spans of the leftmost match at or after `from` into
 * out[0..cap]. out[0] is the whole match, out[k] is group k, and a group that
 * did not participate is {-1, -1}. IRREGEX_MATCH on a match, IRREGEX_OK when
 * there is none, negative on error.
 *
 * *written reports how many spans the PATTERN has, not how many were written,
 * so a cap that came up short sizes the retry without a second question. That
 * is irregex_group_count() + 1: the groups plus out[0], the whole match. The
 * two verbs count differently on purpose - this one sizes a buffer, that one
 * answers how many groups you may ask for.
 * -w is honored here too: a span the word rule rejects is not a match, and the
 * search resumes past it. */
int32_t irregex_captures(irregex_regex *re, const uint8_t *text, size_t len,
                         size_t from, irregex_span *out, size_t cap,
                         size_t *written);

/* How many capture groups the pattern declares, excluding the whole match. */
int32_t irregex_group_count(irregex_regex *re, uint32_t *out);

/* The number of the group named name[0..len]: IRREGEX_MATCH with *out set when
 * the pattern declares it, IRREGEX_OK when it does not (absence is an answer,
 * not a fault), negative on error. */
int32_t irregex_group_index(irregex_regex *re, const uint8_t *name, size_t len,
                            uint32_t *out);

/* The name group `index` was declared with: IRREGEX_MATCH with *out set when it
 * has one, IRREGEX_OK when it is a plain "(...)". The inverse of
 * irregex_group_index, and the one direction you cannot get any other way --
 * without it, turning a match into a keyed record means re-scanning the pattern
 * for (?P<...>) spellings, which is easy to get subtly wrong (an escaped \( and
 * a (?: both fool the obvious scan).
 *
 * *out borrows the handle: the bytes are the parser's own name storage, or
 * PCRE2's name table inside the compiled code, so they are valid until
 * irregex_free and cost no copy. index 0 is the whole match, which is never
 * named; an index past irregex_group_count is IRREGEX_INVALID, since the count
 * is knowable and walking off the end is a bug rather than an absence. */
int32_t irregex_group_name(irregex_regex *re, uint32_t index,
                           irregex_text *out);

/* ── the row protocol ────────────────────────────────────────────── */

/* This is the shape every analytic answer comes back in, no matter which
 * library produced it. libgist, librelate, and libblast each export their own
 * producer (gist_run / relate_run / blast_run); every one of them returns an
 * irregex_rows * walked by the four symbols below. A host asking three
 * packages three questions still learns one way to read an answer.
 *
 * What a row MEANS is declared once in contract/analytic.toml ([row_schemas])
 * and lowered into a generated decoder per language. A verb reusing an
 * existing schema costs zero new C surface. The plane's own compatibility
 * axis is irregex_schema_digest, not irregex_abi_version.
 *
 * Ownership is the cursor's arena: every row, nested row, and text stays
 * valid until irregex_rows_close. A row borrowed past that call is a
 * use-after-free. */

/* Value tags. A field's tag comes from its [row_schemas] declaration, so a
 * decoder knows the shape before it reads; the tag on the wire is what lets it
 * FAIL rather than mis-read when the two disagree. */
#define IRREGEX_VAL_TEXT 0u  /* ptr/len: UTF-8 bytes, NOT NUL-terminated */
#define IRREGEX_VAL_I64 1u   /* integer                                  */
#define IRREGEX_VAL_F64 2u   /* real                                     */
#define IRREGEX_VAL_BOOL 3u  /* integer, 0 or 1                          */
#define IRREGEX_VAL_ENUM 4u  /* integer = ordinal; field.nested = enum id */
#define IRREGEX_VAL_TEXTS 5u /* ptr/len: irregex_text[]                  */
#define IRREGEX_VAL_ROWS 6u  /* ptr/len: irregex_row[]; field.nested = schema id */

/* [row_enums] ordinals. Append-only: an ordinal above the highest a binding
 * knows is UNKNOWN, and must be surfaced as such rather than guessed. */
#define IRREGEX_GRADE_NONE 0u
#define IRREGEX_GRADE_WEAK 1u
#define IRREGEX_GRADE_MODERATE 2u
#define IRREGEX_GRADE_STRONG 3u
#define IRREGEX_GRADE_IDENTICAL 4u
#define IRREGEX_CHANNEL_COPIES 0u
#define IRREGEX_CHANNEL_TWINS 1u
#define IRREGEX_CHANNEL_SHAPES 2u
#define IRREGEX_CHANNEL_ANY 3u
#define IRREGEX_UNIT_FILE 0u
#define IRREGEX_UNIT_FUNCTION 1u
#define IRREGEX_UNIT_MATCH 2u

typedef struct irregex_row irregex_row;

/* One field of one row. Deliberately a flat tagged record rather than a union:
 * a union saves 16 bytes against queries that scan megabytes, and costs every
 * binding an anonymous-type parse its FFI layer may not support. `tag` selects
 * exactly one payload; the others are zero. */
typedef struct {
  uint32_t tag;
  uint32_t reserved; /* always 0 */
  int64_t integer;   /* I64 · BOOL · ENUM ordinal */
  double real;       /* F64 */
  const void *ptr;   /* TEXT bytes · TEXTS irregex_text[] · ROWS irregex_row[] */
  size_t len;        /* element count for ptr (bytes for TEXT) */
} irregex_value;

/* One result row. `schema_id` names a [row_schemas] table, whose field order IS
 * `values`. `present` bit i is clear when field i is absent - which is NOT the
 * same as zero: distance 0.0 means identical, so a binding must be able to tell
 * "no distance" from "no distance between them". Schemas cap at 64 fields.
 *
 * Rows BORROW the cursor arena: they, their nested rows, and their texts stay
 * valid until irregex_rows_close. */
struct irregex_row {
  uint32_t schema_id;
  uint32_t nvalues;
  uint64_t present;
  const irregex_value *values;
};

/* One declared field, for irregex_schema_get. `name` is static and
 * NUL-terminated. `nested` is the schema id for ROWS, the enum id for ENUM, and
 * 0 otherwise. */
typedef struct {
  const char *name;
  uint32_t tag;
  uint32_t nested;
  int32_t optional;
  int32_t reserved;
} irregex_field;

/* One declared row schema. Set struct_size to sizeof(irregex_schema). */
typedef struct {
  uint32_t struct_size;
  uint32_t id;
  const char *name; /* static, NUL-terminated */
  uint32_t nfields;
  uint32_t reserved;
  const irregex_field *fields;
} irregex_schema;

/* Answer-level facts no row can carry. `foreign` is load-bearing for the
 * retrieval verbs in sibling libraries: it counts query fingerprints the
 * corpus has NEVER seen, so a caller can tell "your text isn't in this repo"
 * from "no results". `omitted` is what a budget trimmed, so a truncated answer
 * says so. Set struct_size to sizeof(irregex_stats). */
#define IRREGEX_SOURCE_LIVE 0u
#define IRREGEX_SOURCE_ATLAS 1u
#define IRREGEX_SOURCE_SHELF 2u
typedef struct {
  uint32_t struct_size;
  uint32_t source; /* IRREGEX_SOURCE_*: which tier answered */
  uint64_t elapsed_ns;
  uint64_t files_considered;
  uint64_t refreshed; /* files re-sketched into a warm answer */
  uint64_t foreign;
  uint64_t omitted;
  uint64_t rows;
} irregex_stats;

/* ── the shared warm corpus ─────────────────────────────────────────────────
 *
 * The thing every analytic producer is HANDED. gist_run, relate_run, and
 * blast_run all take an open engine, so unlike the verbs it cannot be one symbol
 * per library: an engine is only interpretable by the copy of the engine code
 * that made it, and each of those libraries statically carries its own. An
 * opener here is one function for all four, which is what makes passing a handle
 * across two of them defined behavior rather than a segfault.
 *
 * An engine is shareable across threads for queries; a cancel token is the one
 * handle another thread may touch while a query runs. */

/* An opaque warm corpus. Open one, ask every package's verbs with it, close it
 * last - after every cursor drawn from it. */
typedef struct irregex_engine irregex_engine;

/* An opaque cancellation token. Trip it from any thread. */
typedef struct irregex_cancel irregex_cancel;

/* Stand a corpus up over roots[0..nroots] (NUL-terminated paths); writes the
 * handle to *out. nroots == 0 walks the CWD and is not an error. Returns
 * IRREGEX_OK, or a negative status with the reason in irregex_last_fault. */
int32_t irregex_engine_open(const char *const *roots, size_t nroots,
                            irregex_engine **out);

/* Release a corpus from irregex_engine_open. Close its cursors first. */
void irregex_engine_close(irregex_engine *engine);

/* Allocate a fresh (unset) token; writes it to *out. Returns IRREGEX_OK or a
 * negative status. */
int32_t irregex_cancel_new(irregex_cancel **out);

/* Trip a token: every in-flight query using it stops. Thread-safe. */
void irregex_cancel_request(irregex_cancel *token);

/* Free a token, after every query using it has returned. */
void irregex_cancel_free(irregex_cancel *token);

/* An opaque analytic row cursor. Produced by a sibling library's …_run; walked
 * and freed here. */
typedef struct irregex_rows irregex_rows;

/* Fill *out with the next row. Returns IRREGEX_MATCH (a row was written),
 * IRREGEX_OK (end of stream; *out untouched), or a negative status. */
int32_t irregex_rows_next(irregex_rows *rows, irregex_row *out);

/* Fill up to cap rows into out[0..cap]; writes the count to *written. Returns
 * IRREGEX_MATCH (>=1 written), IRREGEX_OK (end, 0 written), or a negative
 * status.
 *
 * An answer is materialized into a single cursor arena, so every row, nested
 * row, and text stays valid until irregex_rows_close - not merely until the
 * next pull. A batching host can therefore hold many batches at once without
 * copying. */
int32_t irregex_rows_next_batch(irregex_rows *rows, irregex_row *out, size_t cap,
                                size_t *written);

/* Fill *out with the answer-level stats. Valid at any point; the counters are
 * final once the cursor is drained. IRREGEX_OK, or IRREGEX_INVALID for a NULL
 * or wrongly-sized *out. */
int32_t irregex_rows_stats(irregex_rows *rows, irregex_stats *out);

/* Free a cursor from a sibling library's …_run. Everything its rows borrow
 * dies with it; a row held past this call is a use-after-free. */
void irregex_rows_close(irregex_rows *rows);

/* A stable, static, NUL-terminated digest of this library's WHOLE row-schema
 * table. A binding compares it to the digest its decoder was generated from, so
 * a stale shared library is a loud startup failure rather than a silently
 * mis-decoded row. Never NULL. */
const char *irregex_schema_digest(void);

/* How many row schemas this library declares (ids are 1..count, contiguous). */
uint32_t irregex_schema_count(void);

/* Fill *out with schema `id` (1-based). Returns IRREGEX_OK, or IRREGEX_INVALID
 * for an unknown id or a NULL / wrongly-sized *out. Lets a binding NAME a
 * digest mismatch instead of only detecting one; `name` and `fields` are static
 * and outlive every call. */
int32_t irregex_schema_get(uint32_t id, irregex_schema *out);

#ifdef __cplusplus
}
#endif

#endif /* IRREGEX_H */
