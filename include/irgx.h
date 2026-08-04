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
 * terminate the host. On a negative status, irgx_last_fault gives the
 * per-incident detail behind it.
 *
 * This header is also the SUBSTRATE the rest of the ecosystem speaks:
 * librelate, libgist, and libblast each link this library and return these
 * status codes, this fault struct, these pattern flags, and the same row
 * cursor walked by the irgx_rows_* symbols below. A host that links two of
 * them reads one vocabulary, not two spellings of the same word. */
#ifndef IRGX_H
#define IRGX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── versions ────────────────────────────────────────────────────── */

/* C-ABI version for THIS library; bump on any breaking change so a consumer
 * can reject a mismatched shared object. Additive symbols do not bump it.
 * Independent of libgist's session-ABI version — they are separate axes. */
uint32_t irgx_abi_version(void);

/* The engine semantic version (e.g. "1.0.0"), NUL-terminated, static-lifetime,
 * never NULL. Lets a binding version-gate the library it loaded. */
const char *irgx_version(void);

/* The vendored PCRE2 version the IRGX_PCRE arm runs on. "Which regex
 * grammar do I have" is two numbers; this is the second. */
const char *irgx_pcre2_version(void);

/* ── the shared status vocabulary ────────────────────────────────── */

/* Non-negative = success (IRGX_OK ran with no match, IRGX_MATCH had at
 * least one); negative = the call did not produce a result. IRGX_STALE is
 * the one negative that is NOT an error: a tier declined and the caller should
 * answer through its fallback, unchanged. */
#define IRGX_OK 0
#define IRGX_MATCH 1
#define IRGX_STALE (-1)
#define IRGX_OOM (-2)
#define IRGX_OPEN_FAILED (-3)
#define IRGX_INVALID (-4)

/* A static, NUL-terminated human message for a status code. For a log line,
 * never for a decision — the typed code is the contract. Pure reader: it does
 * not disturb the fault slot, so it is safe to call before irgx_last_fault. */
const char *irgx_status_message(int32_t code);

/* ── the fault detail ────────────────────────────────────────────── */

/* Which ruler `irgx_fault.at` is measured in. One offset, two possible
 * subjects: a byte in the file being read, or a byte in the pattern being
 * compiled. It used to be inferable rather than stated -- `at` meant a file
 * offset unless `path` came back NULL -- so every caller wrote the same
 * three-clause conjunction, and a missed clause points a caret at the wrong
 * string. IRGX_AT_NONE is 0 because byte 0 is a real offset: absence cannot
 * be spelled by `at` itself, so a reader that only wants "is there a position at
 * all" still gets it from a zero test.
 *
 * This field is the ABI-1 `has_at` boolean widened in place -- same offset, same
 * width -- so struct_size cannot catch the difference and a v1 header over a v2
 * library would read a pattern offset as a file one. That is what
 * irgx_abi_version returning 2 is for; gate on it, not on the size. */
#define IRGX_AT_NONE 0    /* no offset: about the file/allocation as a whole */
#define IRGX_AT_FILE 1    /* a byte offset within `path`                     */
#define IRGX_AT_PATTERN 2 /* a byte offset within the compiled PATTERN       */

/* Detail for the LAST failing call on THIS thread, filled by
 * irgx_last_fault. Set struct_size yourself before the call; the layout is
 * append-only, so an unknown size fails closed rather than misreading. */
typedef struct {
  uint32_t struct_size;
  int32_t status;   /* the status this fault crossed the seam as  */
  int32_t at_space; /* IRGX_AT_*: which ruler `at` is measured in, and zero
                     * when there is no offset at all             */
  const char *name;      /* fault name ("Corrupt"), static, never NULL */
  const uint8_t *path;   /* file it was about, or NULL; NOT NUL-term'd */
  size_t path_len;
  uint64_t at; /* the offset, in the space at_space names; 0 and meaningless
                * when that is IRGX_AT_NONE */
} irgx_fault;

/* Fill *out with this thread's last fault. Returns IRGX_MATCH when one was
 * written, IRGX_OK when the thread has none, or IRGX_INVALID for a NULL
 * or wrongly-sized out. IRGX_OK still writes: every field is cleared and
 * `name` becomes "" (never NULL), so the struct is meaningful either way and a
 * host cannot end up trusting its own uninitialized stack.
 *
 * A non-OK status from a WORK call does not imply a detail exists: an argument
 * guard has nothing to add over irgx_status_message, and a declinature is
 * not a fault at all. IRGX_STALE in particular installs nothing, so do not
 * follow one with a read -- the slot is per-thread and never consumed, so what
 * you would get back is an EARLIER call's fault, which looks exactly like a
 * fresh one. Decide a declinature from the status code and stop there.
 *
 * Reading does not consume -- ask twice, or ask either side of
 * irgx_status_message, and get the same answer. What clears the slot is this
 * thread's next WORK call, which opens a fresh window so that asking after a
 * SUCCESS hands you nothing rather than an older failure. So the two facts are
 * about different things and it is worth not conflating them: reads are free
 * and repeatable, and the deadline is the next call that does work. The
 * borrowed `path` points into the slot and expires with it. */
int32_t irgx_last_fault(irgx_fault *out);

/* ── pattern semantics ───────────────────────────────────────────── */

/* What a pattern MEANS. Shared with libgist, which adds its behavioral bits
 * (quiet, invert, max_count) in the gaps at 3, 4 and 7 — one numbering across
 * the ecosystem, so "ignore case" has a single definition. Any bit outside
 * this set makes irgx_compile return IRGX_INVALID: an unknown flag is
 * never silently dropped. */
#define IRGX_FIXED (1u << 0)       /* -F: fixed string, not a regex     */
#define IRGX_IGNORE_CASE (1u << 1) /* -i: case-insensitive              */
#define IRGX_WORD (1u << 2)        /* -w: word-bounded matches only     */
#define IRGX_SMART_CASE (1u << 5)  /* -S: fold iff pattern has no caps  */
#define IRGX_NO_UNICODE (1u << 6)  /* ASCII classes/fold/boundaries     */
#define IRGX_PCRE (1u << 8)        /* -P: PCRE2 grammar (lookaround...) */
#define IRGX_MULTILINE (1u << 9)   /* (?m): ^ and $ also match a line   */
#define IRGX_DOTALL (1u << 10)     /* (?s): . matches a newline too     */

/* IRGX_MULTILINE is the (?m) question and nothing more, off by default as it
 * is in re, rust-regex, PCRE2 and Go's regexp; \A and \z are the text's ends
 * either way. It is NOT the engine's internal "multiline", which means "the
 * haystack is a buffer, not one line" - that is forced on for every pattern
 * compiled here, because you hand over a whole string and can promise nothing
 * about lines. Under the per-line model the compiler may assume no haystack
 * holds a newline, and \s over "a\nb" found nothing at all. */

/* A pattern may also ask for four of these itself, in the leading (?ims-u) form
 * every host language's own library accepts: i -> IRGX_IGNORE_CASE, s ->
 * IRGX_DOTALL, m -> IRGX_MULTILINE, and (?-u) -> IRGX_NO_UNICODE. Only a
 * LEADING run is folded, and what it says wins over the same bit in `flags`,
 * being the more specific statement. A non-leading (?i) is not a whole-pattern
 * option -- re itself has refused one since 3.11 -- and (?x) / (?U) / (?R) are
 * flags this grammar does not have: both stay in the pattern, so the compile
 * refuses with IRGX_STALE and the retry is IRGX_PCRE, which implements them.
 * The scoped (?i:...) form is the parser's own and needs none of this.
 * IRGX_FIXED means the bytes are data, so nothing is folded under it. */

/* A borrowed UTF-8 span. NOT NUL-terminated; `len` is authoritative. Shared
 * vocabulary: it is how the row protocol below carries every string, and how
 * irgx_group_name hands one back, so a host writes one reader for both. */
typedef struct {
  const uint8_t *ptr;
  size_t len;
} irgx_text;

/* ── the regex plane ─────────────────────────────────────────────── */

/* A compiled pattern. Opaque, and SINGLE-THREADED: it owns the scratch its
 * finds run in, so two threads sharing one handle corrupt a match rather than
 * race a counter. Compile one per thread — the compile is pure. */
typedef struct irgx_regex irgx_regex;

/* One byte range [start, end) in the searched text, or {-1, -1} for a capture
 * group the match did not enter. Signed because absence is a real answer:
 * "(a)|(b)" always leaves one of the two unset. */
typedef struct {
  int64_t start;
  int64_t end;
} irgx_span;

/* Compile pattern[0..len] under `flags` and write the handle to *out.
 * IRGX_OK on success; negative on failure, with the reason available from
 * irgx_last_fault. IRGX_SMART_CASE resolves here, against the same
 * has-uppercase predicate the CLI's -S runs. (pattern NULL with len 0 is the
 * empty pattern, which compiles — a language whose empty string carries no data
 * pointer hands that in without meaning anything by it. NULL with len != 0 is
 * IRGX_INVALID.)
 *
 * A REFUSED PATTERN answers with the one thing you can act on -- whether a
 * slower engine here would take it -- and it answers on the RETURN VALUE, so
 * you never have to reach for the fault to find out what to do next:
 *
 *   IRGX_STALE   - the linear grammar cannot express it (lookaround, a
 *                     backreference, an atomic group) but PCRE2 can. Recompile
 *                     the same pattern with IRGX_PCRE and it succeeds. This
 *                     is a DECLINATURE, not a failure: *out is untouched, and
 *                     irgx_last_fault stays silent, because a tier that
 *                     stepped aside has nothing to confess.
 *   IRGX_INVALID - nothing here accepts it. irgx_last_fault names it
 *                     "BadPattern", at_space is IRGX_AT_PATTERN, and `at`
 *                     marks the byte in THE PATTERN where the refusal was
 *                     detected (path is NULL: no file is involved). IRGX_PCRE
 *                     will not rescue it. The name is "Unsupported" instead, with
 *                     no position, in the one case where there was no PCRE2 to
 *                     escalate to at all -- a build without it. A tier that does
 *                     not exist has refused, which is when the declinature above
 *                     becomes this fault.
 *
 * Which one you get is decided by asking PCRE2, not by inspecting the pattern,
 * so it tracks whatever the linked PCRE2 actually supports rather than a list
 * that would drift from it. */
int32_t irgx_compile(const uint8_t *pattern, size_t len, uint32_t flags,
                        irgx_regex **out);

/* Release a handle from irgx_compile. Leaves the fault slot alone, so you
 * can still read the detail that made you clean up. */
void irgx_free(irgx_regex *re);

/* Whether text[0..len] holds a match: IRGX_MATCH yes, IRGX_OK no,
 * negative on error. The cheapest question here — the same walk find_all runs,
 * stopped at the first span rather than materializing the rest, so the two
 * always agree about the same text. (text NULL with len 0 is the empty text, a
 * legitimate question; NULL with len != 0 is IRGX_INVALID.)
 *
 * The buffer is ONE unit: ^ \A match at offset 0 and $ \z at len, and an
 * interior newline is an ordinary byte, not a boundary. There is no corpus
 * behind this plane, so a multi-line buffer is a long line — pass lines
 * separately if you want per-line anchors. */
int32_t irgx_is_match(irgx_regex *re, const uint8_t *text, size_t len);

/* Write the matches in text[0..len] into out[0..cap] and their count into
 * *written. IRGX_MATCH when the TEXT HAS at least one, IRGX_OK when it
 * holds none, negative on error. The status is about the text, never about the
 * window: a count query (cap 0) writes nothing and still returns MATCH.
 *
 * The whole text is one unit, so the iteration rules — empty matches,
 * adjacency, -w filtering — are the engine's own. That is why there is no
 * find(from)-style cursor: a hand-rolled loop is exactly where those rules get
 * re-invented and the nullable patterns come out wrong.
 *
 * This plane reports the WIDEST sequence: every empty match at every byte
 * offset, the one abutting a previous match and the one at the end of the text
 * included. `x*` over "abc" is four spans — (0,0) (1,1) (2,2) (3,3) — which is
 * what Python's re.finditer shows for the same input.
 *
 * That is deliberate, and it is NOT what a grep prints. A grep-class tool drops
 * the trailing empty match, so `gist --json` reports four submatches for the
 * line "abc\n" where this verb reports five for the same four bytes. The widest
 * sequence is the right thing to publish here because thinning is subtractive:
 * a binding can reproduce its own ecosystem's convention by removing spans (Go
 * and Rust both skip an empty match abutting the previous one and resume at the
 * next character; the bundled bindings do exactly that), and no binding can
 * recover a span the ABI never reported. Diff against a grep and expect the
 * trailing empty span; diff against a general-purpose regex library and expect
 * agreement.
 *
 * `cap` is a window over the answer, not a limit on the search: at most cap
 * spans are written, and *written reports how many the TEXT HAS -- so a short
 * window sizes its own retry, exactly as irgx_captures does for a short group
 * buffer. The two are siblings and used to disagree here, which cost every
 * caller the same grow-and-rescan loop: with a saturating count, "did I get
 * everything?" was undecidable, since written == cap is equally a full window
 * and an exact fit. Size cap at len + 1 to be sure of one pass, or pass cap 0
 * with a NULL out to ask only how many there are. */
int32_t irgx_find_all(irgx_regex *re, const uint8_t *text, size_t len,
                         irgx_span *out, size_t cap, size_t *written);

/* ── the window plane ────────────────────────────────────────────────────────
 *
 * A search bounded to [from, to] while every zero-width assertion still reads
 * text[0..len] end to end. That second half is the whole point: slicing the text
 * to the same region is a DIFFERENT question, because a slice moves the haystack
 * edges, so $ \z \b and every lookahead at the cut answer about the slice rather
 * than about the text. Python's search(s, pos, endpos) and Rust's find_at are
 * both this question, and neither can be built out of the unbounded verbs above
 * without changing what the pattern means.
 *
 * from <= to <= len is required; anything else is IRGX_INVALID rather than
 * clamped, because a miscomputed bound is a bug worth hearing about. to == len
 * is the inert case and behaves exactly like the unbounded verb.
 *
 * A LIVE bound (to < len) is not something every engine can honor. The linear
 * engine can: the bound is a ceiling on its walk, and its assertions never
 * stopped reading the true text. PCRE2 cannot, structurally — its subject has
 * one length, so stopping a match at `to` means claiming the subject ends there,
 * which moves the anchors. So a pattern on the PCRE arm faults (fault name
 * BoundUnsupported) rather than quietly answering the sliced question. Ask
 * irgx_pattern_windows once after compiling; it is a property of the pattern,
 * not of the call.
 *
 * Group spans take a start bound (irgx_captures's `from`) and no ceiling: the
 * capture VM has no `to` yet. Stated rather than left to be discovered. */

/* Whether this pattern's engine can honor a live `to` bound: 1 yes, 0 no. */
int32_t irgx_pattern_windows(irgx_regex *re);

/* irgx_is_match over the window [from, to]. */
int32_t irgx_is_match_in(irgx_regex *re, const uint8_t *text, size_t len,
                         size_t from, size_t to);

/* irgx_find_all over the window [from, to]. The `cap` and `written` contract is
 * irgx_find_all's, counting what the WINDOW holds. */
int32_t irgx_find_all_in(irgx_regex *re, const uint8_t *text, size_t len,
                         size_t from, size_t to, irgx_span *out, size_t cap,
                         size_t *written);

/* Write the group spans of the leftmost match at or after `from` into
 * out[0..cap]. out[0] is the whole match, out[k] is group k, and a group that
 * did not participate is {-1, -1}. IRGX_MATCH on a match, IRGX_OK when
 * there is none, negative on error.
 *
 * *written reports how many spans the PATTERN has, not how many were written,
 * so a cap that came up short sizes the retry without a second question. That
 * is irgx_group_count() + 1: the groups plus out[0], the whole match. The
 * two verbs count differently on purpose - this one sizes a buffer, that one
 * answers how many groups you may ask for.
 * -w is honored here too: a span the word rule rejects is not a match, and the
 * search resumes past it. */
int32_t irgx_captures(irgx_regex *re, const uint8_t *text, size_t len,
                         size_t from, irgx_span *out, size_t cap,
                         size_t *written);

/* How many capture groups the pattern declares, excluding the whole match. */
int32_t irgx_group_count(irgx_regex *re, uint32_t *out);

/* The number of the group named name[0..len]: IRGX_MATCH with *out set when
 * the pattern declares it, IRGX_OK when it does not (absence is an answer,
 * not a fault), negative on error. */
int32_t irgx_group_index(irgx_regex *re, const uint8_t *name, size_t len,
                            uint32_t *out);

/* The name group `index` was declared with: IRGX_MATCH with *out set when it
 * has one, IRGX_OK when it is a plain "(...)". The inverse of
 * irgx_group_index, and the one direction you cannot get any other way --
 * without it, turning a match into a keyed record means re-scanning the pattern
 * for (?P<...>) spellings, which is easy to get subtly wrong (an escaped \( and
 * a (?: both fool the obvious scan).
 *
 * *out borrows the handle: the bytes are the parser's own name storage, or
 * PCRE2's name table inside the compiled code, so they are valid until
 * irgx_free and cost no copy. index 0 is the whole match, which is never
 * named; an index past irgx_group_count is IRGX_INVALID, since the count
 * is knowable and walking off the end is a bug rather than an absence. */
int32_t irgx_group_name(irgx_regex *re, uint32_t index,
                           irgx_text *out);

/* ── the slate plane ─────────────────────────────────────────────────────────
 *
 * Everything above is about ONE pattern. A slate is about N of them over one
 * text, in a single pass, and it keeps WHICH pattern found what. That last
 * clause is the whole reason it exists: N calls to irgx_is_match give the same
 * answer at N times the byte cost, and one fused "a|b|c" gives it in one pass
 * while throwing the attribution away.
 *
 * Two questions and no cursor:
 *
 *   irgx_slate_is_match - does ANY of them match? The cheapest one, and where a
 *                         batch workload spends its time: a SIMD literal roll
 *                         rejects a hopeless text with no engine run at all, and
 *                         can answer YES outright when a pattern's literals
 *                         decide it.
 *   irgx_slate_which    - WHICH of them match, as ascending indices into the
 *                         compile list.
 *
 * There is no per-pattern span verb, and that is an edge rather than an omission
 * to apologize for. A slate is a CLASSIFIER: once you know pattern 7 is in this
 * text, irgx_find_all on pattern 7 is the walk you would have run anyway,
 * against a text now known to be worth walking.
 *
 * The unit is the whole text, exactly as it is for the single-pattern plane, so
 * irgx_slate_which names pattern i if and only if irgx_is_match on pattern i
 * alone would have said yes -- for every pattern and every text, including the
 * anchored and the nullable ones. Two verbs of one library must not tell you
 * different things about the same string.
 *
 * A handle is SINGLE-THREADED for the same reason a regex handle is: it owns the
 * per-scan scratch. Compile one per thread; the compile is pure. */

/* A compiled slate. Opaque. */
typedef struct irgx_slate irgx_slate;

/* One pattern of a slate: the bytes, and the same flag word irgx_compile takes.
 * Layout is append-only, so a later field is a compatible extension.
 *
 * IRGX_MULTILINE and IRGX_DOTALL are the two flags a slate cannot carry, and
 * they are REFUSED (IRGX_INVALID) rather than ignored: passing them means you
 * believe something about the answer you are about to get. A pattern whose own
 * head says (?m) or (?s) is refused the same way, with `refused` naming it.
 * Every other pattern flag means here exactly what it means there,
 * IRGX_SMART_CASE included -- resolved at compile against the same
 * has-uppercase predicate, and a leading (?i) / (?-u) likewise stays that one
 * pattern's own. */
typedef struct {
  const uint8_t *pattern;
  size_t len;
  uint32_t flags;
} irgx_slate_pattern;

/* Compile patterns[0..count] as one slate and write the handle to *out.
 * IRGX_OK on success; IRGX_STALE / IRGX_INVALID with the same meanings
 * irgx_compile gives them, decided the same way (by asking PCRE2).
 *
 * *refused receives the INDEX of the pattern that caused a refusal, and may be
 * NULL if you do not care. It is the diagnosis a slate needs and a single
 * pattern does not: with two hundred patterns, "one of them is unsupported" is
 * not an actionable answer. Admission is all-or-nothing -- one refusal costs the
 * whole slate -- so a host that wants the other hundred and ninety-nine drops
 * the named index and recompiles.
 *
 * The pattern bytes are COPIED; they need not outlive this call. count 0 is an
 * empty slate, which is the natural answer to a config file that listed no
 * patterns and not an error: nothing matches, and both verbs say so. patterns
 * may be NULL when count is 0, because "the address of no array" has no other
 * spelling in some hosts. */
int32_t irgx_slate_compile(const irgx_slate_pattern *patterns, size_t count,
                           size_t *refused, irgx_slate **out);

/* Release a handle from irgx_slate_compile. Leaves the fault slot alone. */
void irgx_slate_free(irgx_slate *slate);

/* How many patterns the slate holds. Also the exact cap at which
 * irgx_slate_which can never come up short. */
size_t irgx_slate_len(const irgx_slate *slate);

/* Whether ANY pattern in the slate matches text[0..len]: IRGX_MATCH yes,
 * IRGX_OK no, negative on error. (text NULL with len 0 is the empty text, a
 * legitimate question; NULL with len != 0 is IRGX_INVALID.) */
int32_t irgx_slate_is_match(irgx_slate *slate, const uint8_t *text, size_t len);

/* Write the indices of every pattern matching text[0..len] into out[0..cap],
 * ascending, and their count into *written. IRGX_MATCH when at least one
 * matched, IRGX_OK when none did, negative on error.
 *
 * *written is how many matched whether or not cap held them -- irgx_find_all's
 * contract, so a short buffer sizes its own retry. Unlike there, you can always
 * avoid the retry: the count can never exceed irgx_slate_len. */
int32_t irgx_slate_which(irgx_slate *slate, const uint8_t *text, size_t len,
                         uint32_t *out, size_t cap, size_t *written);

/* ── the row protocol ────────────────────────────────────────────── */

/* This is the shape every analytic answer comes back in, no matter which
 * library produced it. libgist, librelate, and libblast each export their own
 * producer (gist_run / relate_run / blast_run); every one of them returns an
 * irgx_rows * walked by the four symbols below. A host asking three
 * packages three questions still learns one way to read an answer.
 *
 * What a row MEANS is declared once in contract/analytic.toml ([row_schemas])
 * and lowered into a generated decoder per language. A verb reusing an
 * existing schema costs zero new C surface. The plane's own compatibility
 * axis is irgx_schema_digest, not irgx_abi_version.
 *
 * Ownership is the cursor's arena: every row, nested row, and text stays
 * valid until irgx_rows_close. A row borrowed past that call is a
 * use-after-free. */

/* Value tags. A field's tag comes from its [row_schemas] declaration, so a
 * decoder knows the shape before it reads; the tag on the wire is what lets it
 * FAIL rather than mis-read when the two disagree. */
#define IRGX_VAL_TEXT 0u  /* ptr/len: UTF-8 bytes, NOT NUL-terminated */
#define IRGX_VAL_I64 1u   /* integer                                  */
#define IRGX_VAL_F64 2u   /* real                                     */
#define IRGX_VAL_BOOL 3u  /* integer, 0 or 1                          */
#define IRGX_VAL_ENUM 4u  /* integer = ordinal; field.nested = enum id */
#define IRGX_VAL_TEXTS 5u /* ptr/len: irgx_text[]                  */
#define IRGX_VAL_ROWS 6u  /* ptr/len: irgx_row[]; field.nested = schema id */

/* [row_enums] ordinals. Append-only: an ordinal above the highest a binding
 * knows is UNKNOWN, and must be surfaced as such rather than guessed. */
#define IRGX_GRADE_NONE 0u
#define IRGX_GRADE_WEAK 1u
#define IRGX_GRADE_MODERATE 2u
#define IRGX_GRADE_STRONG 3u
#define IRGX_GRADE_IDENTICAL 4u
#define IRGX_CHANNEL_COPIES 0u
#define IRGX_CHANNEL_TWINS 1u
#define IRGX_CHANNEL_SHAPES 2u
#define IRGX_CHANNEL_ANY 3u
#define IRGX_UNIT_FILE 0u
#define IRGX_UNIT_FUNCTION 1u
#define IRGX_UNIT_MATCH 2u

typedef struct irgx_row irgx_row;

/* One field of one row. Deliberately a flat tagged record rather than a union:
 * a union saves 16 bytes against queries that scan megabytes, and costs every
 * binding an anonymous-type parse its FFI layer may not support. `tag` selects
 * exactly one payload; the others are zero. */
typedef struct {
  uint32_t tag;
  uint32_t reserved; /* always 0 */
  int64_t integer;   /* I64 · BOOL · ENUM ordinal */
  double real;       /* F64 */
  const void *ptr;   /* TEXT bytes · TEXTS irgx_text[] · ROWS irgx_row[] */
  size_t len;        /* element count for ptr (bytes for TEXT) */
} irgx_value;

/* One result row. `schema_id` names a [row_schemas] table, whose field order IS
 * `values`. `present` bit i is clear when field i is absent - which is NOT the
 * same as zero: distance 0.0 means identical, so a binding must be able to tell
 * "no distance" from "no distance between them". Schemas cap at 64 fields.
 *
 * Rows BORROW the cursor arena: they, their nested rows, and their texts stay
 * valid until irgx_rows_close. */
struct irgx_row {
  uint32_t schema_id;
  uint32_t nvalues;
  uint64_t present;
  const irgx_value *values;
};

/* One declared field, for irgx_schema_get. `name` is static and
 * NUL-terminated. `nested` is the schema id for ROWS, the enum id for ENUM, and
 * 0 otherwise. */
typedef struct {
  const char *name;
  uint32_t tag;
  uint32_t nested;
  int32_t optional;
  int32_t reserved;
} irgx_field;

/* One declared row schema. Set struct_size to sizeof(irgx_schema). */
typedef struct {
  uint32_t struct_size;
  uint32_t id;
  const char *name; /* static, NUL-terminated */
  uint32_t nfields;
  uint32_t reserved;
  const irgx_field *fields;
} irgx_schema;

/* Answer-level facts no row can carry. `foreign` is load-bearing for the
 * retrieval verbs in sibling libraries: it counts query fingerprints the
 * corpus has NEVER seen, so a caller can tell "your text isn't in this repo"
 * from "no results". `omitted` is what a budget trimmed, so a truncated answer
 * says so. Set struct_size to sizeof(irgx_stats). */
#define IRGX_SOURCE_LIVE 0u
#define IRGX_SOURCE_ATLAS 1u
#define IRGX_SOURCE_SHELF 2u
typedef struct {
  uint32_t struct_size;
  uint32_t source; /* IRGX_SOURCE_*: which tier answered */
  uint64_t elapsed_ns;
  uint64_t files_considered;
  uint64_t refreshed; /* files re-sketched into a warm answer */
  uint64_t foreign;
  uint64_t omitted;
  uint64_t rows;
} irgx_stats;

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
typedef struct irgx_engine irgx_engine;

/* An opaque cancellation token. Trip it from any thread. */
typedef struct irgx_cancel irgx_cancel;

/* Stand a corpus up over roots[0..nroots] (NUL-terminated paths); writes the
 * handle to *out. nroots == 0 walks the CWD and is not an error. Returns
 * IRGX_OK, or a negative status with the reason in irgx_last_fault. */
int32_t irgx_engine_open(const char *const *roots, size_t nroots,
                            irgx_engine **out);

/* Release a corpus from irgx_engine_open. Close its cursors first. */
void irgx_engine_close(irgx_engine *engine);

/* Allocate a fresh (unset) token; writes it to *out. Returns IRGX_OK or a
 * negative status. */
int32_t irgx_cancel_new(irgx_cancel **out);

/* Trip a token: every in-flight query using it stops. Thread-safe. */
void irgx_cancel_request(irgx_cancel *token);

/* Free a token, after every query using it has returned. */
void irgx_cancel_free(irgx_cancel *token);

/* An opaque analytic row cursor. Produced by a sibling library's …_run; walked
 * and freed here. */
typedef struct irgx_rows irgx_rows;

/* Fill *out with the next row. Returns IRGX_MATCH (a row was written),
 * IRGX_OK (end of stream; *out untouched), or a negative status. */
int32_t irgx_rows_next(irgx_rows *rows, irgx_row *out);

/* Fill up to cap rows into out[0..cap]; writes the count to *written. Returns
 * IRGX_MATCH (>=1 written), IRGX_OK (end, 0 written), or a negative
 * status.
 *
 * An answer is materialized into a single cursor arena, so every row, nested
 * row, and text stays valid until irgx_rows_close - not merely until the
 * next pull. A batching host can therefore hold many batches at once without
 * copying. */
int32_t irgx_rows_next_batch(irgx_rows *rows, irgx_row *out, size_t cap,
                                size_t *written);

/* Fill *out with the answer-level stats. Valid at any point; the counters are
 * final once the cursor is drained. IRGX_OK, or IRGX_INVALID for a NULL
 * or wrongly-sized *out. */
int32_t irgx_rows_stats(irgx_rows *rows, irgx_stats *out);

/* Free a cursor from a sibling library's …_run. Everything its rows borrow
 * dies with it; a row held past this call is a use-after-free. */
void irgx_rows_close(irgx_rows *rows);

/* A stable, static, NUL-terminated digest of this library's WHOLE row-schema
 * table. A binding compares it to the digest its decoder was generated from, so
 * a stale shared library is a loud startup failure rather than a silently
 * mis-decoded row. Never NULL. */
const char *irgx_schema_digest(void);

/* How many row schemas this library declares (ids are 1..count, contiguous). */
uint32_t irgx_schema_count(void);

/* Fill *out with schema `id` (1-based). Returns IRGX_OK, or IRGX_INVALID
 * for an unknown id or a NULL / wrongly-sized *out. Lets a binding NAME a
 * digest mismatch instead of only detecting one; `name` and `fields` are static
 * and outlive every call. */
int32_t irgx_schema_get(uint32_t id, irgx_schema *out);

#ifdef __cplusplus
}
#endif

#endif /* IRGX_H */
