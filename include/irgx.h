/* irregex — a regex over a buffer you already hold, and the corpus planes built
 * on top of it.
 *
 * The floor is deliberately small: compile a pattern, then ask is_match /
 * find_all / captures about bytes in your process. A host that wants only that
 * links this and gets nothing it did not ask for.
 *
 * Above the floor, this ABI also carries the warm corpus planes the sibling
 * products share — opening an engine over a tree, searching and walking it,
 * sieving literals, and the codex verbs over a persisted index. What is
 * deliberately NOT here is the session: the resident pull cursor and gist_run
 * live in libgist, whose header is gist.h and whose symbols are gist_*, and the
 * kinship / compose producers live in librelate and libblast.
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

/* What a pattern MEANS. Bits 4 and 7 are behavioral rather than semantic and
 * belong to tree search, not to irgx_compile. libgist reuses this numbering and
 * alone owns the gap at bit 3 (GIST_QUIET) — one numbering across the
 * ecosystem, so "ignore case" has a single definition. Any bit outside this set
 * makes irgx_compile return IRGX_INVALID: an unknown flag is never silently
 * dropped. */
#define IRGX_FIXED (1u << 0)       /* -F: fixed string, not a regex     */
#define IRGX_IGNORE_CASE (1u << 1) /* -i: case-insensitive              */
#define IRGX_WORD (1u << 2)        /* -w: word-bounded matches only     */
#define IRGX_MAX_COUNT (1u << 4)   /* -m: tree search, max_count is set */
#define IRGX_SMART_CASE (1u << 5)  /* -S: fold iff pattern has no caps  */
#define IRGX_NO_UNICODE (1u << 6)  /* ASCII classes/fold/boundaries     */
#define IRGX_INVERT (1u << 7)      /* -v: select the NON-matching lines */
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

/* An opaque cancellation token. Trip it from any thread. Declared here, above
 * the plane that opens one, because a search takes a token and a corpus makes
 * one -- so the type is vocabulary shared by two planes rather than the warm
 * engine's private noun. */
typedef struct irgx_cancel irgx_cancel;

/* ── the request: one struct, so the verb count stops tracking the option count ─
 *
 * Every question about a buffer is asked with an irgx_input. This is the shape
 * that stops the surface from doubling: a bounded search arrived as
 * irgx_is_match_in beside irgx_is_match, and adding anchored and earliest the
 * same way is four more names per verb, each a separate declaration to bind in
 * three languages and a separate paragraph to keep true. A struct absorbs those
 * as FIELDS, so the next mode is a bit rather than an ABI.
 *
 * ZERO IS TODAY. A struct you memset to zero -- then stamp struct_size on -- is
 * an unanchored leftmost search over the whole text with no cancellation. Every
 * field's 0 is its documented default, so a host writes only what it means.
 *
 * struct_size IS FAIL-CLOSED. A size this build does not recognize is
 * IRGX_INVALID, never a best-effort read of the prefix it thinks it recognizes:
 * the alternative is a v1 caller and a v2 engine agreeing on a struct whose
 * meaning drifted, which is the failure irgx_abi_version exists to make loud.
 * The layout is APPEND-ONLY. Never widen a field in place -- ABI 2 widened
 * `has_at` and that is exactly why the version probe had to exist.
 *
 * `text` IS THE WHOLE TEXT, AND STAYS SO. `from` and `to` bound where matching
 * may begin and must stop; they do NOT move the edges the pattern reasons
 * about. This is the one property that makes a bounded search different from
 * searching a slice, and the reason a caller cannot get it by slicing: $ still
 * means the end of `text`, \b still reads the byte before `from`, and a
 * look-behind still sees what precedes the window. Slice instead and every one
 * of those silently starts answering about the cut.
 *
 * A LIVE `to` IS NOT UNIVERSALLY HONORABLE. PCRE2's subject has one length, so
 * the PCRE2 arm declines a bound rather than pretending -- ask
 * irgx_pattern_windows once after compiling, which is a property of the pattern
 * and not of the call. Bounds are checked, never clamped: from > to, to > len,
 * or from > len is IRGX_INVALID, because a miscomputed bound is a bug in the
 * caller's arithmetic and silently trimming it hides the day it appears. */

/* Match must START at `from`. This is NOT rewriting the pattern with \A: it
 * constrains where the SEARCH may begin and leaves the pattern's own assertions
 * about `text` exactly as they were. The distinction matters at from > 0, where
 * \A still means offset zero and this means offset `from`. */
#define IRGX_MODE_ANCHORED (1u << 0)
/* Report the first accepting position rather than the leftmost-first match --
 * the earliest end, not the preferred one. What a host wants when the question
 * is "is there a match at all, cheaply" and a shorter answer is still an answer;
 * what it must NOT use when the span itself is the answer. */
#define IRGX_MODE_EARLIEST (1u << 1)
/* `to`: search to the end of the text. Spelled, so that leaving `to` zero means
 * an empty window rather than accidentally meaning everything. */
#define IRGX_TO_END ((size_t) - 1)
/* `pattern`: any pattern of the slate may answer. The default, and meaningless
 * to a single-pattern handle, which always answers as pattern 0. */
#define IRGX_PATTERN_ANY ((uint32_t) - 1)

typedef struct {
  uint32_t struct_size; /* sizeof(irgx_input); set it yourself   */
  uint32_t mode;        /* IRGX_MODE_* bits; 0 = leftmost, unanchored */
  const uint8_t *text;  /* the WHOLE text: what $ \b and look-around read */
  size_t len;
  size_t from;          /* where matching may begin                      */
  size_t to;            /* where it must stop; IRGX_TO_END for all of it  */
  irgx_cancel *cancel;  /* NULL is uncancellable                         */
  uint32_t pattern;     /* IRGX_PATTERN_ANY, or one slate pattern id      */
  uint32_t reserved;    /* always 0                                      */
} irgx_input;

/* ── the ceilings: what a search may spend, in the currency each engine spends ─
 *
 * The engine already HAS ceilings and you cannot see them: PCRE2 runs under a
 * hardcoded ten-million step budget and a ten-thousand frame depth, and the
 * determinizer declines at its powerset cap. Those are right for a search a
 * person is waiting on and wrong in both directions for a library -- too
 * generous to be a safety property when the pattern came from a stranger, too
 * mean for a batch job that would rather spend a minute than be declined.
 *
 * 0 MEANS THIS ENGINE'S DEFAULT, not "unlimited", so a zeroed struct asks for
 * exactly what you get today. A ceiling the chosen engine does not spend is
 * INERT rather than an error: the linear engine cannot exceed a step budget
 * because it cannot backtrack, and refusing a host that defensively set one
 * would punish the caution this exists to permit. */
typedef struct {
  uint32_t struct_size; /* sizeof(irgx_options)                          */
  uint32_t flags;       /* the IRGX_* flag bits irgx_compile takes today  */
  uint64_t steps;       /* PCRE2 match steps before it gives up          */
  size_t heap_bytes;    /* bytes of heap one match may hold (PCRE2)      */
  uint32_t depth;       /* PCRE2 recursion frames                        */
  uint32_t states;      /* DFA states the determinizer may mint          */
} irgx_options;

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

/* Whether this pattern can report EARLIEST-mode spans: 1 yes, 0 no. Like
 * irgx_pattern_windows, a property of the pattern rather than of the call —
 * ask once after compiling.
 *
 * 0 is a REFUSAL, not a slower path: a span request under IRGX_MODE_EARLIEST
 * then faults (Unsupported) instead of quietly returning the leftmost-first
 * match wearing an earliest label. PCRE2 declines because it exposes no
 * inspectable program, and so does any assertion-bearing pattern, whose
 * determinized states depend on the gap they were entered at — something a walk
 * starting mid-buffer cannot reconstruct. The mode is inert on the boolean
 * verbs either way, since existence does not depend on WHICH match is reported,
 * so a host only needs this before asking for spans. */
int32_t irgx_pattern_earliest(irgx_regex *re);

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

/* ── the munch plane ─────────────────────────────────────────────────────────
 *
 * Every plane above answers a SEARCH question: it scans forward looking for a
 * place a pattern would fit. A tokenizer needs the opposite one, and it is the
 * missing primitive between "does this regex match" and "lex this file":
 * starting at EXACTLY this offset, which pattern reaches furthest?
 *
 * Two entries carry it:
 *
 *   irgx_munch_compile - N patterns into as many anchored automata as they
 *                        need, with PARTIAL refusal. One terminal outside the
 *                        linear syntax must not cost the other hundred and
 *                        fifty, so a declining group is halved and retried, and
 *                        what could not be taken is read back with
 *                        irgx_munch_declined.
 *   irgx_munch_scan    - the longest (or shortest) match beginning at your
 *                        offset, among the patterns you currently permit,
 *                        naming every pattern that reached the winning length.
 *
 * WHY THIS AND NOT AN AUTOMATON. The obvious alternative is to export the DFA -
 * next_state, is_match_state, an accelerator - and let a host build maximal
 * munch itself. This library will not, because a host stepping states is a
 * second opinion about what a pattern means, and one engine that disagrees with
 * itself is worse than one that is missing a verb. (The seal over the regex
 * kernel exists because a second, smaller parser inside this tree once
 * disagreed about the zero-width \< and \> boundaries and silently pruned two
 * thirds of a matching corpus.) So the RULE crosses this ABI, not the table.
 *
 * TIES ARE YOURS. Longest is only half of a lexer's rule; the tie-break
 * (declared precedence, literal beats regex, first-declared-wins) is a property
 * of your grammar rather than of the automaton. A scan therefore reports EVERY
 * pattern that reached the winning length, ascending, and has no opinion about
 * which deserves it.
 *
 * A handle is SINGLE-THREADED, like the two planes above: it owns the winner
 * buffer and the permission set every scan rewrites. */

/* A compiled anchored slate. Opaque. */
typedef struct irgx_munch irgx_munch;

/* One terminal of a lexer slate: the bytes, and nothing else. Layout is
 * append-only, so a later field is a compatible extension.
 *
 * There is no per-pattern flag word, which is the one place this differs from
 * irgx_slate_pattern -- and the difference is forced rather than chosen. A munch
 * determinizes every pattern TOGETHER, under one set of options, so "pattern 3
 * is case-insensitive" is not a thing the machine can be. Options are the
 * slate's, passed once to irgx_munch_compile. */
typedef struct {
  const uint8_t *pattern;
  size_t len;
} irgx_munch_pattern;

/* One pattern the slate could not take, and why. The reason is carried rather
 * than inferred because the four have different owners and different repairs.
 *
 * IRGX_MUNCH_STATES and IRGX_MUNCH_BUFFER_ANCHOR are a budget and a wall, and a
 * caller acts on the difference: the first says a bigger build would take this
 * pattern, the second says none ever will. */
typedef struct {
  uint32_t pattern;
  uint32_t why;
} irgx_munch_refusal;

#define IRGX_MUNCH_SYNTAX 0u        /* the parser rejected the pattern      */
#define IRGX_MUNCH_STATES 1u        /* this build's max_states bound        */
#define IRGX_MUNCH_WORD_CONTEXT 2u  /* \b, with no left context to resolve  */
#define IRGX_MUNCH_BUFFER_ANCHOR 3u /* \A or \z -- no budget admits it      */

/* What a scan found: how far it reached, and how many patterns got there.
 *
 * len 0 is a RESULT, not an absence -- a pattern like a* accepts the empty
 * string. The status tells them apart: IRGX_MATCH means something accepted,
 * IRGX_OK means nothing starts here. A lexer that would spin forever advancing
 * on a zero-length token can therefore see it and say so.
 *
 * count is how many patterns reached len whether or not cap held them --
 * irgx_find_all's contract, so a short buffer sizes its own retry. Unlike there,
 * the retry is always avoidable: the count can never exceed irgx_munch_len. */
typedef struct {
  size_t len;
  size_t count;
} irgx_munch_token;

#define IRGX_MUNCH_LONGEST 0u  /* maximal munch: >>= over >               */
#define IRGX_MUNCH_SHORTEST 1u /* the shortest non-empty reading instead  */

/* Compile patterns[0..count] as one anchored slate under `flags`.
 *
 * IRGX_OK with a handle whenever at least one pattern was taken. A PARTIAL
 * refusal is success, read with irgx_munch_declined -- a slate of a hundred and
 * fifty terminals where one declined is a working lexer, and erroring on it
 * would make your fallback path the common path. This is the one place munch and
 * slate differ on policy, and it is why they are two planes: a classifier that
 * silently dropped a pattern would misreport which patterns matched, while a
 * lexer that refused to build over one bad terminal would simply not lex.
 *
 * IRGX_STALE -- a declinature, not a fault -- when NOTHING could be taken. There
 * is no handle to read reasons from in that case; ask a different engine.
 *
 * `flags` is a SUBSET of the pattern plane's: IRGX_IGNORE_CASE, IRGX_NO_UNICODE
 * and IRGX_DOTALL are honored, and the other five are REFUSED (IRGX_INVALID)
 * rather than ignored, because honoring one here would be a lie you cannot see:
 *
 *   IRGX_PCRE       - the PCRE2 arm has no anchored-longest-over-N automaton at
 *                     all, so there is nothing to be longest among.
 *   IRGX_WORD       - \b resolves against the bytes straddling a gap, and the
 *                     byte before your offset is not in the text this automaton
 *                     was determinized over.
 *   IRGX_SMART_CASE - smart case is a question about ONE pattern's text, and
 *                     these options are the whole slate's.
 *   IRGX_FIXED      - a literal is expressible as a pattern; a flag that
 *                     rewrote every terminal slate-wide is not what a lexer
 *                     with a mix of literals and regexes wants.
 *   IRGX_MULTILINE  - an anchored automaton has no answer to the (?m) question
 *                     either way. It starts where you pointed, so ^ holds at
 *                     every scan offset with or without the flag, and a
 *                     longest-match walk never learns where the buffer ended,
 *                     so $ and \z are reachable from neither. \A still means
 *                     the buffer's start and is false at a nonzero offset.
 *
 * Note IRGX_DOTALL is honored HERE and refused by irgx_slate_compile. The three
 * planes carry three different masks because they can honor different things; do
 * not assume one from another.
 *
 * The pattern bytes are read during determinization and NOT retained, so they
 * need not outlive this call. count 0 is an empty slate -- a working handle that
 * matches nothing, as it is for irgx_slate_compile -- and patterns may be NULL
 * when count is 0. */
int32_t irgx_munch_compile(const irgx_munch_pattern *patterns, size_t count,
                           uint32_t flags, irgx_munch **out);

/* Release a handle from irgx_munch_compile. Leaves the fault slot alone. */
void irgx_munch_free(irgx_munch *munch);

/* How many patterns the slate can name at once -- the exact cap at which
 * irgx_munch_scan's winner buffer can never come up short.
 *
 * The ADMITTED count, not the compile-list count you already know: a declined
 * pattern can never win, so it can never be written, and sizing for it would be
 * sizing for an impossibility. */
size_t irgx_munch_len(const irgx_munch *munch);

/* Write every pattern the slate could not take into out[0..cap], ascending, and
 * their count into *written. IRGX_MATCH when at least one declined, IRGX_OK when
 * the slate took everything, negative on error.
 *
 * A separate verb rather than an out-parameter on compile, because taking
 * everything is the normal case and the diagnosis is only wanted when it isn't. */
int32_t irgx_munch_declined(const irgx_munch *munch, irgx_munch_refusal *out,
                            size_t cap, size_t *written);

/* The match beginning at EXACTLY `at`: the longest one under IRGX_MUNCH_LONGEST,
 * the shortest non-empty one under IRGX_MUNCH_SHORTEST. Writes the winning
 * length and count to *tok and the winning pattern ids, ascending, to
 * out[0..cap]. IRGX_MATCH when something accepted, IRGX_OK when nothing starts
 * here, negative on error.
 *
 * allow[0..nallow] is which patterns you will accept HERE, in your own pattern
 * ordinals; NULL (with nallow 0) permits every one. Admitting an ordinal the
 * slate declined is a documented no-op, so a host with a fallback for its blind
 * terminals need not also remember which they were.
 *
 * The restriction is part of the WALK, and that is load-bearing rather than an
 * optimization: one long illegal match hides every short legal one behind it, so
 * filtering the answer afterward returns nothing where the correct answer is a
 * shorter token. This is lex's start conditions, tree-sitter's valid-symbol set,
 * and Lezer's contextual tokenizer, and it costs one AND per reported end and
 * nothing per byte. A restriction permitting NOTHING is a real question with a
 * knowable answer (IRGX_OK), not an argument error: a lexer state can legitimately
 * reach a point where no terminal is legal.
 *
 * at == len is legal, and asks the only question left at the end of the input:
 * does anything accept the empty string. at > len is IRGX_INVALID. */
int32_t irgx_munch_scan(irgx_munch *munch, const uint8_t *text, size_t len,
                        size_t at, const uint32_t *allow, size_t nallow,
                        uint32_t pick, irgx_munch_token *tok, uint32_t *out,
                        size_t cap);

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

/* The cancellation token this plane hands out is declared with the request
 * vocabulary near the top of this header, because a search takes one. */

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

/* ── the line plane ──────────────────────────────────────────────────────────
 *
 * The grid every grep-shaped host rebuilds by hand, and the one place the
 * off-by-one lives. The engines here answer in byte offsets; a user reads rows,
 * and the translation is not as simple as counting '\n' — a final line with no
 * terminator is still a line, and an offset sitting ON a terminator belongs to
 * the line that terminator ENDS, not the one after it.
 */

/* One line of the grid. `content_end` and `term_end` are separate on purpose:
 * render with the first, slice with the second, and a host never has to guess
 * whether the file ended "\n", "\r\n", or with no terminator at all. */
typedef struct {
  /* 1-based, matching what -n prints and what an editor jumps to. Clamping a
   * band at the top of the file shortens it; it never renumbers. */
  uint64_t number;
  uint64_t start;
  /* One past the last CONTENT byte: terminator excluded, and a CRLF's '\r'
   * KEPT — ripgrep's default without --crlf, and what the matching engines in
   * this library see. A host that strips the '\r' for display but matches on
   * the unstripped bytes stays consistent with them. */
  uint64_t content_end;
  /* One past the terminator, so the next line's `start`. Equals the text length
   * for a final unterminated line, which is still a line. */
  uint64_t term_end;
} irgx_line;

/* How many lines text[0..len] holds. IRGX_MATCH when non-empty, IRGX_OK for
 * empty text. An unterminated tail counts, because a host printing n rows must
 * print that one too. */
int32_t irgx_lines_count(const uint8_t *text, size_t len, uint64_t *out);

/* The band around byte `at`: up to `before` rows preceding it, the row holding
 * it, then up to `after` following. `at == len` is legal and lands on the tail.
 *
 * *center receives the BAND-RELATIVE index of the row holding `at` — the number
 * a caret needs, and one a caller cannot derive from *written, because a band
 * clipped at the start of the text has fewer preceding rows than it asked for.
 * Pass NULL if you do not need it. */
int32_t irgx_lines_context(const uint8_t *text, size_t len, size_t at,
                           size_t before, size_t after, irgx_line *out,
                           size_t cap, size_t *written, size_t *center);

/* The whole grid. *written is the count the TEXT holds, so a short `cap` sizes
 * its retry rather than truncating silently. */
int32_t irgx_lines_split(const uint8_t *text, size_t len, irgx_line *out,
                         size_t cap, size_t *written);

/* ── the literal plane, and the tables the engine decides with ───────────────
 *
 * What a pattern PROMISES about the bytes any match must contain — the input an
 * indexer needs to build a prefilter — plus the Unicode tables this engine folds
 * and classifies with, so a host is not left reimplementing case folding against
 * a different Unicode version than the one doing the matching.
 */

typedef struct irgx_literals irgx_literals;

/* `max_len` when the pattern has no upper bound at all (`a+`, `.*`). */
#define IRGX_LEN_UNBOUNDED UINT32_MAX

/* Which set. Indices into irgx_promise's arrays. */
#define IRGX_PLACE_REQUIRED 0u
#define IRGX_PLACE_PREFIX 1u
#define IRGX_PLACE_SUFFIX 2u
#define IRGX_PLACE_WHOLE 3u
#define IRGX_PLACE_COUNT 4u

/* How much a set proves. Ordered, so `verdict >= IRGX_LITERALS_CANDIDATE` is
 * the "safe to eliminate on" test. */
#define IRGX_LITERALS_NONE 0u      /* no set; proves nothing either way, scan */
#define IRGX_LITERALS_CANDIDATE 1u /* absence of EVERY member proves no match;
                                    * presence proves nothing and must be
                                    * verified */
#define IRGX_LITERALS_EXACT 2u     /* containment and matching are one question */

/* The whole-pattern promise, and the size of every set, in one read. Read this
 * BEFORE a set: it is what says whether the set you are about to read is a
 * guarantee or a guess, and a prefilter built on the wrong one silently drops
 * real matches. */
typedef struct {
  uint32_t struct_size;
  uint32_t verdict[IRGX_PLACE_COUNT];
  uint32_t count[IRGX_PLACE_COUNT];
  uint32_t anchored;
  uint32_t nullable; /* the pattern can match the empty string */
  uint32_t min_len;
  uint32_t max_len; /* IRGX_LEN_UNBOUNDED when the pattern has no ceiling */
                    /* (a real ceiling is never this value, so the sentinel
                     * cannot collide with a measured length) */
  /* A 256-bit set of the bytes a match may BEGIN with, as four little-endian
   * words: bit (b & 63) of first_bytes[b >> 6]. Empty means unknown, not "no
   * byte can start a match". */
  uint64_t first_bytes[4];
  /* A structural fingerprint of the LANGUAGE the pattern denotes, not of its
   * text: two patterns spelled differently that accept the same set share it.
   * For caching a derived artifact across spellings. */
  uint64_t signature[2];
} irgx_promise;

/* An inclusive codepoint range. */
typedef struct {
  uint32_t lo;
  uint32_t hi;
} irgx_range;

/* Extract what `re` promises about its matches. The handle copies what it needs,
 * so it borrows nothing from `re` and the two are freed independently. */
int32_t irgx_literals_open(irgx_regex *re, irgx_literals **out);

/* Release a handle from irgx_literals_open. */
void irgx_literals_free(irgx_literals *lits);

/* Fill *out with the promise. Set struct_size to sizeof(irgx_promise) first. */
int32_t irgx_literals_promise(const irgx_literals *lits, irgx_promise *out);

/* One set by `place`, with its grade written to *verdict — not optional, because
 * the grade is how the exact-versus-inexact property rides along with the bytes
 * instead of being looked up separately and forgotten.
 *
 * The irgx_text rows BORROW the handle's arena and die with
 * irgx_literals_free; copy anything that must outlive it. */
int32_t irgx_literals_set(const irgx_literals *lits, uint32_t place,
                          uint32_t *verdict, irgx_text *out, size_t cap,
                          size_t *written);

/* Every codepoint that case-folds together with `cp`, INCLUDING `cp` — the
 * orbit, not a pair, because 'k', 'K' and U+212A KELVIN SIGN are one class.
 * This is the table -i folds with, so a host building its own index folds
 * identically rather than approximately. */
int32_t irgx_fold_orbit(uint32_t cp, uint32_t *out, size_t cap,
                        size_t *written);

/* The inclusive ranges of the Unicode property name[0..len] ("Letter", "Greek",
 * "Nd", …), ascending and non-overlapping. An unknown name FAULTS rather than
 * answering empty, so a misspelled property and an empty class cannot look
 * alike. */
int32_t irgx_property_ranges(const uint8_t *name, size_t len, irgx_range *out,
                             size_t cap, size_t *written);

/* Whether `cp` is in property name[0..len]: IRGX_MATCH yes, IRGX_OK no,
 * negative for an unknown property. The membership test without materializing
 * the ranges. */
int32_t irgx_property_has(const uint8_t *name, size_t len, uint32_t cp);

/* The Unicode version these tables were generated from. A host whose own tables
 * disagree is a host whose prefilter and this engine disagree about what a
 * letter is. */
int32_t irgx_unicode_version(irgx_text *out);

/* ── the needle plane ────────────────────────────────────────────────────────
 *
 * Many literals, one pass, with attribution — the question a regex alternation
 * answers slowly and a wordlist scanner answers quickly.
 */

typedef struct irgx_needles irgx_needles;

/* Which machine seated the set. Reported, not chosen: the tier is a consequence
 * of the needles, and a host that wants to know what it will cost asks. */
#define IRGX_NEEDLE_TIER_NONE 0u
#define IRGX_NEEDLE_TIER_MEMMEM 1u      /* one needle: a plain substring find */
#define IRGX_NEEDLE_TIER_LITERAL_SET 2u /* a few: SIMD multi-substring */
#define IRGX_NEEDLE_TIER_TRAWL 3u       /* many: Aho-Corasick */

typedef struct {
  const uint8_t *needle;
  size_t len;
} irgx_needle;

/* One occurrence, attributed to the needle that produced it. */
typedef struct {
  uint32_t needle; /* index into the compiled list */
  uint32_t reserved;
  size_t start;
  size_t end;
} irgx_occurrence;

/* What the set is and which machine answers about it. */
typedef struct {
  uint32_t struct_size;
  /* The two tiers can differ: presence may be answerable by a cheaper machine
   * than attribution, and a host budgeting a scan needs the one it will use. */
  uint32_t presence_tier;
  uint32_t attributed_tier;
  uint32_t reserved;
  size_t count;   /* needles SEATED, which a refusal makes < the count passed */
  size_t longest;
  size_t bytes;
} irgx_needle_shape;

/* Compile list[0..count] into one scanner. ALL OR NOTHING: there is no partial
 * set, so a non-OK return means no handle was written and nothing was seated.
 *
 * *refused is a DIAGNOSIS, not a count: on a refusal it receives the INDEX of
 * the needle that caused it, and on success it is untouched. That is the answer
 * a wordlist needs and a single needle does not -- with four hundred terms,
 * "one of them is empty" is not actionable. NULL if you do not care which.
 *
 * An empty needle is refused (fault `NeedleTooShort`), not accepted: it occurs
 * at every position, so seating one would turn every answer into the haystack's
 * own length and bury the terms actually asked about.
 *
 * `flags` must be 0. No bit is defined for this plane yet, and an undefined bit
 * is IRGX_INVALID rather than ignored -- so a host that guessed IRGX_IGNORE_CASE
 * hears about it instead of silently getting a case-sensitive scanner. */
int32_t irgx_needles_compile(const irgx_needle *list, size_t count,
                             uint32_t flags, size_t *refused,
                             irgx_needles **out);

/* Release a handle from irgx_needles_compile. */
void irgx_needles_free(irgx_needles *handle);

/* How many needles the set holds — the exact `cap` irgx_needles_which never
 * needs to retry at. */
size_t irgx_needles_len(const irgx_needles *handle);

/* Fill *out with the shape. A pure reader: it starts no work, so it cannot
 * disturb the fault a previous call left in irgx_last_fault. */
int32_t irgx_needles_describe(const irgx_needles *handle,
                              irgx_needle_shape *out);

/* Whether ANY needle occurs in text[0..len]: IRGX_MATCH yes, IRGX_OK no. The
 * cheapest question — it stops at the first hit and attributes nothing. */
int32_t irgx_needles_is_match(irgx_needles *handle, const uint8_t *text,
                              size_t len);

/* WHICH needles occur, as ascending indices into the compiled list — presence
 * per needle, NOT one row per occurrence. Size `cap` from irgx_needles_len and
 * this never retries. */
int32_t irgx_needles_which(irgx_needles *handle, const uint8_t *text,
                           size_t len, uint32_t *out, size_t cap,
                           size_t *written);

/* Every occurrence, each carrying its needle index and span. *written is the
 * count the TEXT holds, so a short `cap` sizes its retry. */
int32_t irgx_needles_find_all(irgx_needles *handle, const uint8_t *text,
                              size_t len, irgx_occurrence *out, size_t cap,
                              size_t *written);

/* ── the tree plane: searching a corpus, not a buffer you already hold ──
 *
 * irgx_engine_open → irgx_tree_search → irgx_matches_next* → irgx_matches_close.
 * A cursor comes back on IRGX_OK too -- including IRGX_OK with no records -- so
 * the status reports the ANSWER, never whether there is a handle to release. */

/* A pull handle over one search's records. Opaque; single-threaded. */
typedef struct irgx_cursor irgx_cursor;

/* IRGX_MATCH_LINE is a line the pattern selected; IRGX_MATCH_CONTEXT is a
 * neighbour carried along by before_context/after_context. */
#define IRGX_MATCH_LINE 0u
#define IRGX_MATCH_CONTEXT 1u

/* One complete tree-search shape. APPEND-ONLY with a FAIL-CLOSED struct_size:
 * a size this build does not recognize is IRGX_INVALID, never a best-effort
 * read of the prefix it thinks it recognizes.
 *
 * ZERO IS TODAY. Every field's 0 is its documented default, so a memset struct
 * with struct_size stamped on is an unbudgeted, uncancelled, contextless
 * leftmost search for the empty pattern. The budgets read 0 as "unset" rather
 * than "zero allowed" -- which is exactly why max_count, where 0 IS a legal
 * ceiling, needs IRGX_MAX_COUNT to say it is present.
 *
 * `flags` takes IRGX_FIXED, IRGX_IGNORE_CASE, IRGX_WORD, IRGX_MAX_COUNT,
 * IRGX_SMART_CASE, IRGX_NO_UNICODE and IRGX_INVERT. The gap is the point: the
 * warm engine's request has no knob for IRGX_PCRE, IRGX_MULTILINE or
 * IRGX_DOTALL to travel in, and existence-only early halt is said here with
 * max_results = 1 rather than by a second way to say it. Any other bit is
 * IRGX_INVALID, because a host that set one has a wrong belief about what it
 * is about to be told. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  uint64_t max_count;      /* per-file ceiling; needs IRGX_MAX_COUNT   */
  uint64_t before_context; /* -B                                       */
  uint64_t after_context;  /* -A                                       */
  const uint8_t *pattern;
  size_t pattern_len;
  uint64_t timeout_ns;  /* 0 = unbudgeted                              */
  size_t max_results;   /* 0 = unbounded; 1 = existence only           */
  const irgx_cancel *cancel; /* or NULL                                */
} irgx_tree_request;

/* One record. `path` and `line` are borrowed from the CURSOR's arena and stay
 * valid until irgx_matches_close; `spans` likewise. Copy anything you keep. */
typedef struct {
  irgx_text path;
  irgx_text line;
  const irgx_span *spans;
  size_t nspans;
  uint64_t line_number;
  uint32_t kind; /* IRGX_MATCH_LINE | IRGX_MATCH_CONTEXT */
} irgx_match;

/* Run one search over the engine's corpus. Owes irgx_matches_close on every
 * non-negative return. */
int32_t irgx_tree_search(irgx_engine *engine, const irgx_tree_request *req,
                         irgx_cursor **out);

/* Pull one record: IRGX_MATCH for a record, IRGX_OK for a drained stream with
 * `out` untouched. The one-record spelling of irgx_matches_next_batch. */
int32_t irgx_matches_next(irgx_cursor *cursor, irgx_match *out);

/* Pull up to `cap` records in one crossing. *written is what this call
 * CONSUMED, never a total that exists -- so cap == 0 is a legal no-op. */
int32_t irgx_matches_next_batch(irgx_cursor *cursor, irgx_match *out,
                                size_t cap, size_t *written);

/* How many records the stream holds, without advancing it. */
size_t irgx_matches_count(const irgx_cursor *cursor);

/* Release the cursor and every byte its records borrowed. */
void irgx_matches_close(irgx_cursor *cursor);

/* ── the walk plane: which files a search is even allowed to read ──
 *
 * gitignore precedence, the type registry, hidden and binary policy. Answered
 * as a materialized set you iterate, so eligibility is a question you can ask
 * on its own rather than a side effect of searching. */

typedef struct irgx_walk irgx_walk;

/* What a path is FOR -- a total, disjoint partition, so an unfamiliar
 * extension lands in CODE rather than falling through a gap. */
#define IRGX_GENUS_CODE 0u
#define IRGX_GENUS_DOCS 1u
#define IRGX_GENUS_DATA 2u

/* The ceilings this build enforces, so a host sizes its request against the
 * truth instead of a constant it copied. Set struct_size before the call. */
typedef struct {
  uint32_t struct_size;
  uint32_t binary_window; /* bytes sniffed for the binary verdict      */
  uint64_t file_cap;      /* most files one walk may materialize       */
  uint32_t type_rows;     /* rows the type registry holds              */
  uint32_t type_names;    /* distinct type names it answers to         */
  /* The two brace ceilings a `{a,b}` term is expanded under. Exceeding either
   * is IRGX_OOM carrying `BudgetExceeded` -- refused, never allocated. They are
   * separate axes and a host needs both: `brace_cap` bounds the PRODUCT, which
   * `{a}{a}{a}...` slips past at a product of one while still recursing once
   * per group, and `brace_group_cap` bounds that. A host that validates a
   * user's glob against only the first will still build a term this refuses. */
  uint32_t brace_cap;       /* most globs one braced term may name       */
  uint32_t brace_group_cap; /* most groups one braced term may carry     */
} irgx_limits;

/* What a term MEANS. A root is a place to walk from; the rest narrow. */
#define IRGX_TERM_ROOT 0u
#define IRGX_TERM_GLOB 1u
#define IRGX_TERM_GLOB_NOT 2u
#define IRGX_TERM_IGLOB 3u
#define IRGX_TERM_TYPE 4u
#define IRGX_TERM_TYPE_NOT 5u
#define IRGX_TERM_IGNORE_FILE 6u

/* One clause of a walk spec. `text` is borrowed for the duration of the
 * irgx_walk_open call only -- the walk copies what it keeps. */
typedef struct {
  uint32_t kind; /* IRGX_TERM_* */
  uint32_t reserved;
  const uint8_t *text;
  size_t text_len;
} irgx_walk_term;

/* Policy bits. Each is a DECLINATURE of a default the walk would otherwise
 * apply, which is why they read as no_*: the safe spelling is 0. */
#define IRGX_WALK_HIDDEN (1u << 0)          /* descend into dotfiles      */
#define IRGX_WALK_NO_IGNORE (1u << 1)       /* honour no ignore file      */
#define IRGX_WALK_NO_IGNORE_VCS (1u << 2)   /* ... not .gitignore         */
#define IRGX_WALK_NO_IGNORE_DOT (1u << 3)   /* ... not .ignore            */
#define IRGX_WALK_NO_IGNORE_PARENT (1u << 4)/* ... none above the root    */
#define IRGX_WALK_NO_IGNORE_EXCLUDE (1u << 5)/* ... not .git/info/exclude */
#define IRGX_WALK_NO_IGNORE_GLOBAL (1u << 6)/* ... not the global one     */
#define IRGX_WALK_NO_IGNORE_FILES (1u << 7) /* ... none named by a term   */
#define IRGX_WALK_NO_REQUIRE_GIT (1u << 8)  /* VCS rules outside a repo   */
#define IRGX_WALK_IGNORE_FILE_ICASE (1u << 9)
#define IRGX_WALK_FOLLOW (1u << 10)         /* follow symlinks            */
#define IRGX_WALK_ONE_FILE_SYSTEM (1u << 11)
#define IRGX_WALK_GLOB_ICASE (1u << 12)
/* Additionally apply the CORPUS content rules -- unreadable, empty, at or over
 * the per-file ceiling, or binary is NOT a member -- and report each admitted
 * file's length in `irgx_walk_entry.size`. Two consequences, both easy to miss:
 * this NARROWS the set rather than widening it, and it is the only flag that
 * makes the walk read file bytes. Nothing to do with directories. */
#define IRGX_WALK_MEMBERS (1u << 13)
/* Unreadable directories become a COUNT (irgx_walk_gapped) instead of a
 * refusal. Without it an unreadable directory fails the walk -- because
 * "nothing matched" and "we never looked there" are different answers. */
#define IRGX_WALK_TOLERATE_GAPS (1u << 14)

/* One complete eligibility question. APPEND-ONLY, fail-closed struct_size. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;     /* IRGX_WALK_*                                   */
  uint64_t max_depth; /* 0 = unbounded                                 */
  const irgx_walk_term *terms;
  size_t term_count;
} irgx_walk_spec;

/* One eligible file. `path` is borrowed from the walk and dies at
 * irgx_walk_close. */
typedef struct {
  irgx_text path;
  uint64_t size;  /* member length, and 0 unless IRGX_WALK_MEMBERS was set --
                   * reading it costs a file read, so nothing pays for it by
                   * default. 0 here means "not measured", never "empty":
                   * an empty file is not a member and never appears at all. */
  uint32_t genus; /* IRGX_GENUS_* */
  uint32_t reserved;
} irgx_walk_entry;

/* The ceilings this build enforces. */
int32_t irgx_walk_limits(irgx_limits *out);

/* Materialize the eligible set.
 *
 * IRGX_MATCH when at least one file was admitted and IRGX_OK when none was --
 * and in BOTH cases a handle was written and you own it, exactly as a tree
 * search hands back an empty cursor. The status reports the ANSWER, never
 * whether there is something to release.
 *
 * IRGX_INVALID covers every spec this build cannot honor, not only the
 * malformed ones: a null slot, an unrecognized struct_size, an unknown flag
 * bit, a term with uninitialized padding or no text, an unrecognized type
 * name, an unclosed glob class, an unclosed brace. Each would otherwise read
 * as a corpus that happened to be empty. A WELL-FORMED `{a,b}` alternation is
 * not among them -- it expands here, once, into the concrete globs it names,
 * so `-g '*.{js,ts}'` admits exactly what `-g '*.js' -g '*.ts'` admits.
 *
 * IRGX_OPEN_FAILED carries `Corrupt` (or `Oversized`) for an `.irregex.toml`
 * that would not parse, and `AccessDenied` for a walk that could not finish --
 * see IRGX_WALK_TOLERATE_GAPS. IRGX_OOM is the only other failure, and it is
 * two things the status folds together: real allocation failure, and a brace
 * expansion that hit its ceiling. `irgx_last_fault()->name` tells them apart
 * (`OutOfMemory` vs `BudgetExceeded`) -- the second means the spec was fine
 * and the remedy is a smaller glob, not more memory. `irgx_walk_limits()`
 * publishes the two ceilings, so a host can size a glob before sending it
 * rather than discovering them by refusal.
 *
 * So: test the SIGN, not the value. `if (st < 0)` is the failure branch; the
 * reflex `if (st != IRGX_OK)` leaks the handle of every non-empty walk, which
 * is the common case and never the one under test. */
int32_t irgx_walk_open(const irgx_walk_spec *spec, irgx_walk **out);

/* How many entries it holds. */
size_t irgx_walk_count(const irgx_walk *w);

/* How many directories were unreadable but tolerated -- the number that
 * separates "nothing matched" from "we never looked there". */
uint32_t irgx_walk_gapped(const irgx_walk *w);

/* Pull one entry; IRGX_OK once drained. */
int32_t irgx_walk_next(irgx_walk *w, irgx_walk_entry *out);

/* Pull up to `cap` entries in one crossing. */
int32_t irgx_walk_next_batch(irgx_walk *w, irgx_walk_entry *out, size_t cap,
                             size_t *written);

/* Restart iteration. The set is already materialized, so this re-reads
 * nothing from the filesystem. */
void irgx_walk_rewind(irgx_walk *w);

/* Whether this exact path is in the set -- membership, without iterating. */
int32_t irgx_walk_holds(const irgx_walk *w, const uint8_t *path,
                        size_t path_len);

/* Release the walk and every byte it lent out. */
void irgx_walk_close(irgx_walk *w);

/* Whether these bytes read as binary under the same window the walk applies. */
int32_t irgx_walk_binary(const uint8_t *bytes, size_t len);

/* What a path is FOR: *out is one of IRGX_GENUS_*. */
int32_t irgx_walk_genus(const uint8_t *path, size_t len, uint32_t *out);

/* ── the sieve plane: narrowing, so most files are never opened ──
 *
 * Two persisted tiers -- the trigram index and the crest sieve. Every answer
 * is a SUPERSET: a sieve rules documents OUT, it never rules one in, so a
 * candidate still has to be read. */

typedef struct irgx_sieve irgx_sieve;
/* A pattern's narrowing plan, derived once and spent across many queries. */
typedef struct irgx_winnow irgx_winnow;

/* What the artifacts contain, and which tiers are present at all. */
typedef struct {
  uint32_t struct_size;
  uint32_t doc_count;
  uint32_t path_count;
  uint32_t posting_count;
  uint32_t root_count;
  uint32_t has_crest;    /* 1 when the crest tier is present   */
  uint32_t has_codicil;  /* 1 when the sidecar is present      */
  uint32_t reserved;
} irgx_sieve_facts;

/* Which freshness posture is in force -- a total set, so `state` is always one
 * of these three and never 0. A question that cannot be answered is not a
 * fourth state: it is IRGX_INVALID from the call, which writes nothing. */
#define IRGX_FRESH_ANCHORED 1   /* the artifacts date this tree             */
#define IRGX_FRESH_UNANCHORED 2 /* no anchor on disk -- nothing to date     */
#define IRGX_FRESH_FOREIGN 3    /* an anchor, but built over another tree   */

/* Whether the artifacts still describe the tree. `anchor_ns` is the wall clock
 * the verdict is measured against -- so a stale index is a known quantity, not
 * a silent wrong answer.
 *
 * `state` is signed for room to grow and is never negative today; a host that
 * writes a `state < 0` branch is writing dead code. Switch on the three
 * IRGX_FRESH_* values and let an unrecognized one be the future's problem. */
typedef struct {
  uint32_t struct_size;
  int32_t state;
  int64_t anchor_ns;
  int32_t reserved;
} irgx_freshness;

/* What a plan is made of. `idle` is the honest answer that this pattern rules
 * nothing out -- an empty candidate list would have been a lie. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  uint32_t clauses;
  uint32_t atoms;
  uint32_t literals;
  uint32_t alternatives;
  uint32_t sieve_active;
  uint32_t idle;
} irgx_winnow_facts;

/* Open the persisted artifacts in `dir`. Artifacts built over a different tree
 * open INERT rather than wrong. */
int32_t irgx_sieve_open(const uint8_t *dir, size_t dir_len, irgx_sieve **out);

/* Release the sieve and every byte it lent out. */
void irgx_sieve_close(irgx_sieve *s);

/* What this artifact set contains. */
int32_t irgx_sieve_describe(const irgx_sieve *s, irgx_sieve_facts *out);

/* The path a document id names; bytes borrowed until irgx_sieve_close. */
int32_t irgx_sieve_doc_path(const irgx_sieve *s, uint32_t doc, irgx_text *out);

/* The i-th root the artifacts were built over. */
int32_t irgx_sieve_root(const irgx_sieve *s, uint32_t i, irgx_text *out);

/* Documents that could contain this literal, ascending. A superset. */
int32_t irgx_sieve_literal(irgx_sieve *s, const uint8_t *needle, size_t len,
                           uint32_t *out, size_t cap, size_t *written);

/* The same for a union of literals, merged inside the index rather than by N
 * crossings the host stitches together. */
int32_t irgx_sieve_alternation(irgx_sieve *s, const irgx_text *needles,
                               size_t n, uint32_t *out, size_t cap,
                               size_t *written);

/* What a whole plan admits, in document-id order. */
int32_t irgx_sieve_candidates(irgx_sieve *s, const irgx_winnow *w,
                              uint32_t *out, size_t cap, size_t *written);

/* The same set, sequenced by what is cheapest to read. */
int32_t irgx_sieve_reading_list(irgx_sieve *s, const irgx_winnow *w,
                                uint32_t *out, size_t cap, size_t *written);

/* Whether the artifacts still describe the tree. */
int32_t irgx_sieve_freshness(const irgx_sieve *s, irgx_freshness *out);

/* HOW MANY documents changed since the anchor -- the magnitude freshness
 * reduces to a state, for a host deciding whether a rebuild is worth it. */
int32_t irgx_sieve_stale_count(const irgx_sieve *s, size_t *out);

/* Derive a pattern's narrowing plan once. */
int32_t irgx_winnow_of(irgx_regex *re, irgx_winnow **out);

/* Release the plan. */
void irgx_winnow_free(irgx_winnow *w);

/* What the plan is made of, and whether it can narrow at all. */
int32_t irgx_winnow_describe(const irgx_winnow *w, irgx_winnow_facts *out);

/* ── the codex plane: count, locate and restore WITHOUT the text ──
 *
 * A self-index: it answers about a text it does not store, and can hand the
 * text back. Counting costs the PATTERN, not the corpus. */

typedef struct irgx_codex irgx_codex;

/* How the wavelet layer is encoded. ADOPT_MIN picks the smaller of the two per
 * block; PLAIN_ONLY forbids the compressed form, for a host that wants a
 * predictable size over a smaller one. */
#define IRGX_CODEX_ADOPT_MIN 0u
#define IRGX_CODEX_PLAIN_ONLY 1u

/* An INPUT for irgx_codex_options.sample_rate, not a return value anywhere:
 * build no locate layer at all -- the count-only artifact. It is a sentinel
 * rather than 0 because a zeroed options struct has to mean today's default,
 * which is the rule every options struct at this seam keeps. Such an index
 * still counts; irgx_codex_locate and irgx_codex_position then DECLINE with
 * IRGX_STALE, which is a build-time choice being reported, not a failure.
 * (irgx_codex_stats.locates says which you have, and spells "none" as 0.) */
#define IRGX_NO_LOCATE 0xFFFFFFFFu

/* Build options. Zero is the default everywhere: sample_rate 0 takes the
 * build's own, encoding 0 is ADOPT_MIN. */
typedef struct {
  uint32_t struct_size;
  uint32_t sample_rate; /* 0 = this build's default; larger = smaller
                         * index, slower locate; IRGX_NO_LOCATE = build
                         * no locate layer at all                     */
  uint32_t encoding;    /* IRGX_CODEX_*                                */
  uint32_t reserved;
} irgx_codex_options;

/* What the index cost and what it can still do. */
typedef struct {
  uint32_t struct_size;
  uint32_t sample_rate;
  uint32_t locates; /* 1 when the locate layer is present */
  uint32_t reserved;
  size_t text_len;
  size_t index_bytes;
  size_t tree_bytes;
  size_t locate_bytes;
} irgx_codex_stats;

/* A half-open row interval [lo, hi) in the index -- the set of suffixes a
 * pattern prefix still admits. Driving it yourself is what
 * irgx_codex_rows_whole and irgx_codex_rows_extend are for. */
typedef struct {
  size_t lo;
  size_t hi;
} irgx_codex_rows;

/* The longest text this build can index, so a host refuses before allocating. */
size_t irgx_codex_max_text_len(void);

/* Build a self-index over text[0..len). */
int32_t irgx_codex_build(const uint8_t *text, size_t len,
                         const irgx_codex_options *opts, irgx_codex **out);

/* Load a saved index. A blob this build cannot read fails closed. */
int32_t irgx_codex_load(const uint8_t *bytes, size_t len, irgx_codex **out);

/* Release the index. */
void irgx_codex_free(irgx_codex *cx);

/* The length of the text it stands for -- which need not exist any more. */
size_t irgx_codex_len(const irgx_codex *cx);

/* What it cost and what it can still do. */
int32_t irgx_codex_measure(const irgx_codex *cx, irgx_codex_stats *out);

/* How many times `pattern` occurs, in time proportional to the PATTERN. The
 * occurrences are never enumerated to count them. */
int32_t irgx_codex_count(const irgx_codex *cx, const uint8_t *pattern,
                         size_t len, size_t *out);

/* WHERE it occurs, as text offsets. IRGX_STALE when the index was built
 * without the locate layer -- a declinature, not an empty answer. */
int32_t irgx_codex_locate(const irgx_codex *cx, const uint8_t *pattern,
                          size_t len, size_t *out, size_t cap,
                          size_t *written);

/* The text offset one row stands for. */
int32_t irgx_codex_position(const irgx_codex *cx, size_t row, size_t *out);

/* The whole row range: the interval before any character has narrowed it. */
int32_t irgx_codex_rows_whole(const irgx_codex *cx, irgx_codex_rows *out);

/* Narrow a row range by one byte, extending the pattern LEFTWARD -- the
 * backward-search step, so a host can drive its own search. */
int32_t irgx_codex_rows_extend(const irgx_codex *cx, irgx_codex_rows *rows,
                               uint8_t byte);

/* Reconstruct the text from `at` onward. The index IS the text. */
int32_t irgx_codex_extract(irgx_codex *cx, size_t at, uint8_t *out, size_t cap,
                           size_t *written);

/* Serialize the index. *written is the size it NEEDS, so a short cap sizes the
 * retry rather than truncating silently. */
int32_t irgx_codex_save(irgx_codex *cx, uint8_t *out, size_t cap,
                        size_t *written);

#ifdef __cplusplus
}
#endif

#endif /* IRGX_H */
