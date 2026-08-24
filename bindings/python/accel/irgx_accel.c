/* irgx._accel - the hot seam, crossed once instead of ten times over.
 *
 * WHY THIS EXISTS
 *
 * The binding's transport is ctypes, which is a distribution decision and a
 * good one: the wheel needs no compiler, no Python headers and no build step on
 * the installing machine. What it is not is cheap per call. ctypes converts
 * every argument through its own type machinery on every crossing, and that
 * cost scales with the argument count rather than with the work:
 *
 *     irgx_is_match_in   engine  12.7 ns   through ctypes  327 ns
 *     irgx_find_all_in   engine  66.1 ns   through ctypes  585 ns
 *
 * (21-byte subject, "[a-z]+", ReleaseFast, measured against a C driver on the
 * same machine.) A linear-time engine that answers in 66 nanoseconds and then
 * spends 519 of them being called is not a linear-time engine anybody can feel.
 *
 * So this module is the same calls with the marshaling deleted: it takes the
 * caller's own `str`/`bytes` and returns finished Python objects, doing the
 * buffer sizing, the short-window retry and the result construction in C where
 * they cost nothing. Everything above it - Match, findall, split, sub, the
 * lexer plane, the set plane - stays Python and gets faster for free, because
 * every one of them funnels through these twelve verbs. Two of them - `texts`
 * and `group_texts` - go further than deleting the marshaling: they collapse
 * a whole findall, which used to be one crossing per match plus one for the
 * walk, into a single crossing that hands back the finished list.
 *
 * WHAT IT IS NOT
 *
 * Not a second binding. It links nothing, opens nothing and knows no symbol
 * names of its own: `bind()` is handed the engine's function pointers by the
 * ctypes layer that already resolved them, so there is exactly one library
 * loaded, one ABI check, and one place where IRGX_LIB is honored. If this
 * module is missing - an unsupported platform, a free-threaded interpreter, a
 * source checkout - the binding runs on ctypes and answers identically. It is
 * an accelerator, never a dependency.
 *
 * Not the whole ABI either. Sixty-odd verbs cross this boundary; twelve of them
 * are called once per *text* and the rest once per *program* (open, close,
 * describe, compile, build). Accelerating an FM-index build that runs for a
 * second to save 500 nanoseconds is not a saving, it is boilerplate, so the
 * cold planes stay on ctypes where they read better.
 *
 * ERRORS ARE NOT RAISED HERE
 *
 * Every verb returns the engine's own int32 status when it has no result, and a
 * finished Python object when it does. The status vocabulary - which negative
 * means what, which fault detail to read, which sentence to build - already
 * lives in `irgx/_abi.py` and is worth exactly one implementation. So C answers
 * "what happened" and Python still answers "what to say about it", and this
 * file contains no error prose at all.
 */

/* 3.12 is the package's floor, so the stable ABI is pinned there and one binary
 * per platform serves every interpreter from 3.12 forward. METH_FASTCALL only
 * entered the limited API in 3.13; when built against a 3.13+ floor the verbs
 * take the vectorcall path and save the argument tuple, and the #if below is
 * the whole difference between the two. */
#ifndef Py_LIMITED_API
#define Py_LIMITED_API 0x030C0000
#endif

#include <Python.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if Py_LIMITED_API + 0 >= 0x030D0000
#define IRGX_CALL METH_FASTCALL
#define IRGX_ARGS PyObject *const *args, Py_ssize_t nargs
#define IRGX_PASS args, nargs
#define IRGX_NARGS nargs
#define IRGX_ARG(i) args[i]
/* A fastcall implementation has a different signature from PyCFunction, and
 * the method table's field is declared as the latter; the cast is how every
 * extension registers one (CPython's own headers do the same behind
 * _PyCFunction_CAST, which the limited API does not export). */
#define IRGX_VERB(fn) ((PyCFunction)(void (*)(void))(fn))
#else
#define IRGX_CALL METH_VARARGS
#define IRGX_ARGS PyObject *args
#define IRGX_PASS args
#define IRGX_NARGS PyTuple_Size(args)
#define IRGX_ARG(i) PyTuple_GetItem(args, (i))
#define IRGX_VERB(fn) (fn)
#endif

/* ── the engine, as function pointers ──────────────────────────────────── */

typedef struct {
  int64_t start;
  int64_t end;
} irgx_span;

typedef struct {
  size_t len;
  size_t count;
} irgx_munch_token;

typedef struct {
  uint32_t needle;
  uint32_t reserved;
  size_t start;
  size_t end;
} irgx_occurrence;

typedef int32_t (*fn_present)(void *, const uint8_t *, size_t);
typedef int32_t (*fn_indices)(void *, const uint8_t *, size_t, uint32_t *, size_t, size_t *);
typedef int32_t (*fn_is_match_in)(void *, const uint8_t *, size_t, size_t, size_t);
typedef int32_t (*fn_find_all_in)(void *, const uint8_t *, size_t, size_t, size_t, irgx_span *,
                                  size_t, size_t *);
typedef int32_t (*fn_find_first_in)(void *, const uint8_t *, size_t, size_t, size_t, irgx_span *);
typedef int32_t (*fn_captures)(void *, const uint8_t *, size_t, size_t, irgx_span *, size_t,
                               size_t *);
typedef int32_t (*fn_munch_scan)(void *, const uint8_t *, size_t, size_t, const uint32_t *, size_t,
                                 uint32_t, irgx_munch_token *, uint32_t *, size_t);
typedef int32_t (*fn_occurrences)(void *, const uint8_t *, size_t, irgx_occurrence *, size_t,
                                  size_t *);

struct engine_table {
  fn_is_match_in is_match_in;
  fn_find_all_in find_all_in;
  fn_find_first_in find_first_in;
  fn_captures captures;
  fn_present slate_is_match;
  fn_indices slate_which;
  fn_munch_scan munch_scan;
  fn_present needles_is_match;
  fn_indices needles_which;
  fn_occurrences needles_find_all;
};

static struct engine_table engine;

/* The verb this module exports, the ABI symbol it needs, and where the pointer
 * goes. One row per verb and no other registration anywhere: `bind()` is handed
 * every symbol the ctypes layer declares, for every plane, and picks out the
 * ones it can accelerate. A plane that grows a new hot verb adds a row here and
 * nothing else; a plane whose engine is too old to export its symbol simply
 * never appears in `bound()`, and Python keeps using ctypes for it. */
static const struct {
  const char *verb;
  const char *symbol;
  size_t slot;
} table[] = {
    {"is_match", "irgx_is_match_in", offsetof(struct engine_table, is_match_in)},
    {"find_all", "irgx_find_all_in", offsetof(struct engine_table, find_all_in)},
    {"find_first", "irgx_find_first_in", offsetof(struct engine_table, find_first_in)},
    {"captures", "irgx_captures", offsetof(struct engine_table, captures)},
    /* The two whole-answer verbs compose symbols already rowed above, so they
     * bind against the one that distinguishes them; `group_texts` checks its
     * second pointer itself, since a build that has either has both. */
    {"texts", "irgx_find_all_in", offsetof(struct engine_table, find_all_in)},
    {"group_texts", "irgx_captures", offsetof(struct engine_table, captures)},
    {"slate_is_match", "irgx_slate_is_match", offsetof(struct engine_table, slate_is_match)},
    {"slate_which", "irgx_slate_which", offsetof(struct engine_table, slate_which)},
    {"munch_scan", "irgx_munch_scan", offsetof(struct engine_table, munch_scan)},
    {"needles_is_match", "irgx_needles_is_match", offsetof(struct engine_table, needles_is_match)},
    {"needles_which", "irgx_needles_which", offsetof(struct engine_table, needles_which)},
    {"needles_find_all", "irgx_needles_find_all", offsetof(struct engine_table, needles_find_all)},
};

#define VERBS (sizeof(table) / sizeof(table[0]))

static char is_bound[VERBS];

/* ── the subject ───────────────────────────────────────────────────────── */

/* The bytes to search, and whether anybody can move them while we look.
 *
 * A `str` is handed to the engine through its own cached UTF-8 rather than
 * re-encoded: CPython keeps that encoding on the object after the first ask, and
 * for the ASCII case it *is* the object's storage, so a repeated search over the
 * same string copies nothing at all. That is the single largest saving in this
 * file, and it is unavailable from Python, where `s.encode()` mints a new bytes
 * on every call.
 *
 * `immutable` is what decides whether the GIL can be dropped for a long scan: a
 * str and a bytes cannot be rewritten under us, a bytearray or a writable
 * memoryview can. */
typedef struct {
  const uint8_t *bytes;
  Py_ssize_t len;
  int immutable;
  int borrowed; /* holds a Py_buffer that must be released */
  Py_buffer view;
} subject;

static int subject_of(PyObject *o, subject *s) {
  s->borrowed = 0;
  if (PyUnicode_Check(o)) {
    Py_ssize_t n = 0;
    const char *p = PyUnicode_AsUTF8AndSize(o, &n);
    if (p == NULL) return -1;
    s->bytes = (const uint8_t *)p;
    s->len = n;
    s->immutable = 1;
    return 0;
  }
  if (PyBytes_Check(o)) {
    char *p = NULL;
    Py_ssize_t n = 0;
    if (PyBytes_AsStringAndSize(o, &p, &n) < 0) return -1;
    s->bytes = (const uint8_t *)p;
    s->len = n;
    s->immutable = 1;
    return 0;
  }
  if (PyObject_GetBuffer(o, &s->view, PyBUF_SIMPLE) < 0) return -1;
  s->bytes = (const uint8_t *)s->view.buf;
  s->len = s->view.len;
  s->immutable = 0;
  s->borrowed = 1;
  return 0;
}

static void subject_done(subject *s) {
  if (s->borrowed) PyBuffer_Release(&s->view);
}

/* Above this many bytes a scan is long enough that another thread could have
 * used the interpreter while it ran. Below it, the release/reacquire pair costs
 * more than the scan does. Only immutable subjects qualify - dropping the GIL
 * while pointing into a bytearray invites a resize under the engine. */
#define UNLOCK_ABOVE 32768
#define CAN_UNLOCK(s) ((s).immutable && (s).len >= UNLOCK_ABOVE)

/* Run one engine call, holding the interpreter only if it is worth holding.
 * Written once because the choice is per-subject rather than per-verb, and six
 * hand-written copies of a release/reacquire pair is six chances to guard the
 * wrong one. */
#define IRGX_RUN(s, status, call)              \
  do {                                         \
    if (CAN_UNLOCK(s)) {                       \
      Py_BEGIN_ALLOW_THREADS(status) = (call); \
      Py_END_ALLOW_THREADS                     \
    } else {                                   \
      (status) = (call);                       \
    }                                          \
  } while (0)

/* ── scratch ───────────────────────────────────────────────────────────── */

/* Most answers fit here, so most calls allocate nothing. */
#define INLINE_ROWS 128

/* And most of the rest fit here. The engine reports how many rows the TEXT
 * holds rather than how many fit, so a short window is never a wrong answer -
 * only a second pass over the same bytes. This is the width at which that
 * second pass stops being routine, and it is the same number the ctypes path
 * uses, so switching transports never changes how many times a text is read.
 * Sizing at `len + 1` instead - the most matches a text can hold - would mean a
 * 16 MB buffer for a 1 MB text that has four matches in it. */
#define FIRST_WINDOW 4096

/* Rows to ask for first, given how many the text could possibly hold. */
static size_t first_window(size_t most) { return most < FIRST_WINDOW ? most : FIRST_WINDOW; }

/* Point `out` at a buffer of `cap` rows: the caller's stack array when it fits,
 * a fresh allocation otherwise. `*heap` always owns whatever was allocated, so
 * one `PyMem_Free(*heap)` on every exit path is the whole discipline. */
static int widen(size_t cap, size_t row, void *inln, void **heap, void **out) {
  if (cap <= INLINE_ROWS) {
    *out = inln;
    return 0;
  }
  void *grown = PyMem_Realloc(*heap, cap * row);
  if (grown == NULL) {
    PyErr_NoMemory();
    return -1;
  }
  *heap = grown;
  *out = grown;
  return 0;
}

/* ── argument reading ──────────────────────────────────────────────────── */

/* Read a pointer-sized integer without PyArg_ParseTuple.
 *
 * The format-string parsers are perfectly good and cost more than the engine
 * call they are wrapping - the whole point of this file is that a hundred
 * nanoseconds is a lot here. Every argument these verbs take is either an
 * object or a non-negative integer, so reading them directly is both faster and
 * shorter than a format string would be. */
static int as_size(PyObject *o, size_t *out) {
  Py_ssize_t v = PyLong_AsSsize_t(o);
  if (v == -1 && PyErr_Occurred()) return -1;
  if (v < 0) {
    PyErr_SetString(PyExc_ValueError, "offsets, limits and handles cannot be negative");
    return -1;
  }
  *out = (size_t)v;
  return 0;
}

static int arity(Py_ssize_t got, Py_ssize_t want) {
  if (got == want) return 0;
  PyErr_Format(PyExc_TypeError, "expected %zd arguments, got %zd", want, got);
  return -1;
}

/* A verb with no result: the engine's own status, for Python to translate. */
static PyObject *refused(int32_t status) { return PyLong_FromLong((long)status); }

/* One span as (start, end), built directly rather than through Py_BuildValue,
 * whose format parsing costs more than the two integers it makes. */
static PyObject *pair(int64_t start, int64_t end) {
  PyObject *out = PyTuple_New(2);
  if (out == NULL) return NULL;
  PyObject *a = PyLong_FromLongLong((long long)start);
  PyObject *b = PyLong_FromLongLong((long long)end);
  if (a == NULL || b == NULL) {
    Py_XDECREF(a);
    Py_XDECREF(b);
    Py_DECREF(out);
    return NULL;
  }
  PyTuple_SetItem(out, 0, a); /* steals */
  PyTuple_SetItem(out, 1, b);
  return out;
}

/* ── the regex plane ───────────────────────────────────────────────────── */

static PyObject *verb_is_match(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 3) < 0) return NULL;
  size_t rx, from;
  if (as_size(IRGX_ARG(0), &rx) < 0 || as_size(IRGX_ARG(2), &from) < 0) return NULL;
  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;
  size_t n = (size_t)s.len;
  int32_t status;
  IRGX_RUN(s, status, engine.is_match_in((void *)rx, s.bytes, n, from, n));
  subject_done(&s);
  return refused(status);
}

/* The leftmost span as (start, end), or the engine's status when there is none.
 *
 * Not `find_all` with a cap of one. A cap bounds what gets WRITTEN and never
 * what gets walked, because `written` owes the caller how many matches the whole
 * text holds - so a search spelled that way walks every match in the text and
 * tallies them, all of it for spans the caller has no way to read. This asks
 * only for the first and the walk stops there, which is most of what a search
 * over a long text costs. No buffer either: one span on the C stack. */
static PyObject *verb_find_first(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 3) < 0) return NULL;
  size_t rx, from;
  if (as_size(IRGX_ARG(0), &rx) < 0 || as_size(IRGX_ARG(2), &from) < 0) return NULL;
  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;
  size_t n = (size_t)s.len;
  irgx_span span = {0, 0};
  int32_t status;
  IRGX_RUN(s, status, engine.find_first_in((void *)rx, s.bytes, n, from, n, &span));
  subject_done(&s);
  return status == 1 ? pair(span.start, span.end) : refused(status);
}

/* Spans as a list of (start, end), or the engine's status when it refused.
 *
 * `limit` is how many spans the caller wants at most, 0 for all of them, which
 * is the difference between `search` and `finditer` and the reason both are not
 * two entry points. The end bound is always the end of the buffer: the binding
 * expresses `endpos` by shortening the subject, because that is what re means by
 * it, so there is no ceiling left to pass through. */
/* The engine's status when walk_spans could not even ask: a Python exception
 * (out of memory) is already set. Every engine status fits in more than 16
 * bits of headroom above this, so the sentinel can never collide with one. */
#define WALK_PYERR INT32_MIN

/* Every span at or after `from`, into the caller's inline rows or a heap the
 * caller frees. A short window says by how much, and a second pass over
 * unchanged text cannot find a different number, so there is no growth
 * schedule - one retry, sized at the count, and never a third. A caller who
 * asked for a limit has everything they asked for already. On return `*rows`
 * is how many spans `*out` holds; shared by every verb whose answer is the
 * whole walk, so they cannot drift on window discipline. */
static int32_t walk_spans(size_t rx, const subject *s, size_t from, size_t limit,
                          irgx_span *inln, void **heap, irgx_span **out, size_t *rows) {
  size_t n = (size_t)s->len;
  size_t cap = first_window(n + 1);
  if (limit && limit < cap) cap = limit;
  size_t written = 0;
  int32_t status;
  if (widen(cap, sizeof(irgx_span), inln, heap, (void **)out) < 0) return WALK_PYERR;
  IRGX_RUN(*s, status, engine.find_all_in((void *)rx, s->bytes, n, from, n, *out, cap, &written));
  if (status >= 0 && written > cap && limit == 0) {
    cap = written;
    if (widen(cap, sizeof(irgx_span), inln, heap, (void **)out) < 0) return WALK_PYERR;
    IRGX_RUN(*s, status,
             engine.find_all_in((void *)rx, s->bytes, n, from, n, *out, cap, &written));
  }
  *rows = written < cap ? written : cap;
  return status;
}

static PyObject *verb_find_all(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 4) < 0) return NULL;
  size_t rx, from, limit;
  if (as_size(IRGX_ARG(0), &rx) < 0 || as_size(IRGX_ARG(2), &from) < 0 ||
      as_size(IRGX_ARG(3), &limit) < 0)
    return NULL;
  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;

  irgx_span inln[INLINE_ROWS];
  irgx_span *out = NULL;
  void *heap = NULL;
  size_t rows = 0;
  int32_t status = walk_spans(rx, &s, from, limit, inln, &heap, &out, &rows);
  subject_done(&s);
  if (status == WALK_PYERR || status < 0) {
    PyMem_Free(heap);
    return status == WALK_PYERR ? NULL : refused(status);
  }

  PyObject *list = PyList_New((Py_ssize_t)rows);
  if (list == NULL) {
    PyMem_Free(heap);
    return NULL;
  }
  for (size_t i = 0; i < rows; i++) {
    PyObject *span = pair(out[i].start, out[i].end);
    if (span == NULL) {
      Py_DECREF(list);
      PyMem_Free(heap);
      return NULL;
    }
    PyList_SetItem(list, (Py_ssize_t)i, span); /* steals */
  }
  PyMem_Free(heap);
  return list;
}

/* Group spans for the match at `at`, with None for a group not entered, or the
 * status when there was no match to describe.
 *
 * `groups` is what the pattern declares, which is the exact window the ABI
 * documents - it reports how many groups the PATTERN has, not how many it wrote
 * - so the retry below is a belt for a claim rather than a path anyone takes. */
static PyObject *verb_captures(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 4) < 0) return NULL;
  size_t rx, at, groups;
  if (as_size(IRGX_ARG(0), &rx) < 0 || as_size(IRGX_ARG(2), &at) < 0 ||
      as_size(IRGX_ARG(3), &groups) < 0)
    return NULL;
  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;

  irgx_span inln[INLINE_ROWS];
  irgx_span *out = NULL;
  void *heap = NULL;
  size_t cap = groups + 1;
  size_t written = 0;
  int32_t status;
  for (;;) {
    if (widen(cap, sizeof(irgx_span), inln, &heap, (void **)&out) < 0) {
      subject_done(&s);
      return NULL;
    }
    IRGX_RUN(s, status,
             engine.captures((void *)rx, s.bytes, (size_t)s.len, at, out, cap, &written));
    if (status < 0 || written <= cap) break;
    cap = written;
  }
  subject_done(&s);
  if (status != 1) {
    PyMem_Free(heap);
    return refused(status);
  }
  PyObject *list = PyList_New((Py_ssize_t)written);
  if (list == NULL) {
    PyMem_Free(heap);
    return NULL;
  }
  for (size_t i = 0; i < written; i++) {
    PyObject *item;
    if (out[i].start < 0 || out[i].end < 0) {
      item = Py_None;
      Py_INCREF(item);
    } else if ((item = pair(out[i].start, out[i].end)) == NULL) {
      Py_DECREF(list);
      PyMem_Free(heap);
      return NULL;
    }
    PyList_SetItem(list, (Py_ssize_t)i, item); /* steals */
  }
  PyMem_Free(heap);
  return list;
}

/* ── whole answers ─────────────────────────────────────────────────────── */

/* The text one span names, in the caller's own type. `PyUnicode_FromStringAndSize`
 * decodes the UTF-8 slice directly, which is what makes these verbs immune to
 * the byte-to-character translation every span answer forces on a non-ASCII
 * `str`: a TEXT needs no index in either domain. */
static PyObject *text_of(const subject *s, int64_t start, int64_t end, int decode) {
  const char *at = (const char *)s->bytes + start;
  Py_ssize_t width = (Py_ssize_t)(end - start);
  return decode ? PyUnicode_FromStringAndSize(at, width) : PyBytes_FromStringAndSize(at, width);
}

/* A span with no index in the caller's domain: an empty match on a UTF-8
 * continuation byte splits a character `re` has no position for, and would
 * surface as a duplicate of the character it splits. Same rule as the
 * binding's `_on_characters`, applied only when the answer is decoded. */
static int mid_character(const subject *s, int64_t at, int decode) {
  return decode && at < s->len && (s->bytes[at] & 0xC0) == 0x80;
}

/* findall with no groups, as one crossing: the walk, the thinning and every
 * finished text built here, so a page of prose costs one call rather than one
 * plus a slice and an index translation per match. */
static PyObject *verb_texts(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 4) < 0) return NULL;
  size_t rx, from;
  if (as_size(IRGX_ARG(0), &rx) < 0 || as_size(IRGX_ARG(2), &from) < 0) return NULL;
  int decode = PyObject_IsTrue(IRGX_ARG(3));
  if (decode < 0) return NULL;
  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;

  irgx_span inln[INLINE_ROWS];
  irgx_span *out = NULL;
  void *heap = NULL;
  size_t rows = 0;
  int32_t status = walk_spans(rx, &s, from, 0, inln, &heap, &out, &rows);
  if (status == WALK_PYERR || status < 0) {
    subject_done(&s);
    PyMem_Free(heap);
    return status == WALK_PYERR ? NULL : refused(status);
  }

  size_t kept = 0;
  for (size_t i = 0; i < rows; i++)
    if (!mid_character(&s, out[i].start, decode)) kept++;
  PyObject *list = PyList_New((Py_ssize_t)kept);
  if (list == NULL) goto fail;
  for (size_t i = 0, k = 0; i < rows; i++) {
    if (mid_character(&s, out[i].start, decode)) continue;
    PyObject *item = text_of(&s, out[i].start, out[i].end, decode);
    if (item == NULL) goto fail;
    PyList_SetItem(list, (Py_ssize_t)k++, item); /* steals */
  }
  subject_done(&s);
  PyMem_Free(heap);
  return list;

fail:
  subject_done(&s);
  PyMem_Free(heap);
  Py_XDECREF(list);
  return NULL;
}

/* findall with groups, as one crossing: the walk, then the capture pass and
 * the finished group texts per match, all here - N matches used to cost N+1
 * crossings and a Match object each, and now cost one crossing and none.
 * `count` is what the pattern declares; one group answers bare, several answer
 * as a tuple, a group the match did not enter answers None. */
static PyObject *verb_group_texts(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 5) < 0) return NULL;
  size_t rx, from, count;
  if (as_size(IRGX_ARG(0), &rx) < 0 || as_size(IRGX_ARG(2), &from) < 0 ||
      as_size(IRGX_ARG(3), &count) < 0)
    return NULL;
  int decode = PyObject_IsTrue(IRGX_ARG(4));
  if (decode < 0) return NULL;
  if (engine.find_all_in == NULL) {
    PyErr_SetString(PyExc_RuntimeError, "group_texts needs irgx_find_all_in bound");
    return NULL;
  }
  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;
  size_t n = (size_t)s.len;

  irgx_span inln[INLINE_ROWS];
  irgx_span *out = NULL;
  void *heap = NULL;
  size_t rows = 0;
  PyObject *list = NULL;
  irgx_span caps_inln[INLINE_ROWS];
  irgx_span *caps = NULL;
  void *caps_heap = NULL;
  int32_t status = walk_spans(rx, &s, from, 0, inln, &heap, &out, &rows);
  if (status == WALK_PYERR || status < 0) {
    subject_done(&s);
    PyMem_Free(heap);
    return status == WALK_PYERR ? NULL : refused(status);
  }

  size_t kept = 0;
  for (size_t i = 0; i < rows; i++)
    if (!mid_character(&s, out[i].start, decode)) kept++;
  list = PyList_New((Py_ssize_t)kept);
  if (list == NULL) goto fail;

  size_t gcap = count + 1;
  if (widen(gcap, sizeof(irgx_span), caps_inln, &caps_heap, (void **)&caps) < 0) goto fail;
  for (size_t i = 0, k = 0; i < rows; i++) {
    if (mid_character(&s, out[i].start, decode)) continue;
    size_t written = 0;
    int32_t st;
    for (;;) {
      st = engine.captures((void *)rx, s.bytes, n, (size_t)out[i].start, caps, gcap, &written);
      if (st != 1 || written <= gcap) break;
      gcap = written;
      if (widen(gcap, sizeof(irgx_span), caps_inln, &caps_heap, (void **)&caps) < 0) goto fail;
    }
    if (st < 0) { /* a refusal the walk did not hit: hand it back as a status */
      subject_done(&s);
      PyMem_Free(heap);
      PyMem_Free(caps_heap);
      Py_DECREF(list);
      return refused(st);
    }
    if (st != 1 || caps[0].start != out[i].start || caps[0].end != out[i].end) {
      PyErr_Format(PyExc_RuntimeError,
                   "internal disagreement in the engine: find_all reported a match at "
                   "bytes (%lld, %lld), but captures answered differently from the same offset",
                   (long long)out[i].start, (long long)out[i].end);
      goto fail;
    }
    PyObject *item;
    if (count == 1) {
      item = (caps[1].start < 0 || caps[1].end < 0)
                 ? (Py_INCREF(Py_None), Py_None)
                 : text_of(&s, caps[1].start, caps[1].end, decode);
      if (item == NULL) goto fail;
    } else {
      item = PyTuple_New((Py_ssize_t)count);
      if (item == NULL) goto fail;
      for (size_t g = 1; g <= count; g++) {
        PyObject *one;
        if (g >= written || caps[g].start < 0 || caps[g].end < 0) {
          one = Py_None;
          Py_INCREF(one);
        } else if ((one = text_of(&s, caps[g].start, caps[g].end, decode)) == NULL) {
          Py_DECREF(item);
          goto fail;
        }
        PyTuple_SetItem(item, (Py_ssize_t)(g - 1), one); /* steals */
      }
    }
    PyList_SetItem(list, (Py_ssize_t)k++, item); /* steals */
  }
  subject_done(&s);
  PyMem_Free(heap);
  PyMem_Free(caps_heap);
  return list;

fail:
  subject_done(&s);
  PyMem_Free(heap);
  PyMem_Free(caps_heap);
  Py_XDECREF(list);
  return NULL;
}

/* ── indices out of a uint32 window ────────────────────────────────────── */

/* Every attribution verb in this ABI has the same shape - ascending uint32
 * indices into a compiled list, under a cap the caller already knows exactly -
 * so slate_which and needles_which are one implementation asked twice. */
static PyObject *indices_of(fn_indices call, size_t handle, PyObject *text, size_t cap) {
  subject s;
  if (subject_of(text, &s) < 0) return NULL;
  uint32_t inln[INLINE_ROWS];
  uint32_t *out = NULL;
  void *heap = NULL;
  if (widen(cap, sizeof(uint32_t), inln, &heap, (void **)&out) < 0) {
    subject_done(&s);
    return NULL;
  }
  size_t written = 0;
  int32_t status;
  IRGX_RUN(s, status, call((void *)handle, s.bytes, (size_t)s.len, out, cap, &written));
  subject_done(&s);
  if (status < 0) {
    PyMem_Free(heap);
    return refused(status);
  }
  size_t rows = written < cap ? written : cap;
  PyObject *list = PyList_New((Py_ssize_t)rows);
  if (list == NULL) {
    PyMem_Free(heap);
    return NULL;
  }
  for (size_t i = 0; i < rows; i++) {
    PyObject *item = PyLong_FromUnsignedLong(out[i]);
    if (item == NULL) {
      Py_DECREF(list);
      PyMem_Free(heap);
      return NULL;
    }
    PyList_SetItem(list, (Py_ssize_t)i, item); /* steals */
  }
  PyMem_Free(heap);
  return list;
}

static PyObject *present(fn_present call, IRGX_ARGS) {
  if (arity(IRGX_NARGS, 2) < 0) return NULL;
  size_t handle;
  if (as_size(IRGX_ARG(0), &handle) < 0) return NULL;
  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;
  int32_t status;
  IRGX_RUN(s, status, call((void *)handle, s.bytes, (size_t)s.len));
  subject_done(&s);
  return refused(status);
}

/* ── the set plane ─────────────────────────────────────────────────────── */

static PyObject *verb_slate_is_match(PyObject *self, IRGX_ARGS) {
  (void)self;
  return present(engine.slate_is_match, IRGX_PASS);
}

static PyObject *verb_slate_which(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 3) < 0) return NULL;
  size_t slate, cap;
  if (as_size(IRGX_ARG(0), &slate) < 0 || as_size(IRGX_ARG(2), &cap) < 0) return NULL;
  return indices_of(engine.slate_which, slate, IRGX_ARG(1), cap);
}

/* ── the lexer plane ───────────────────────────────────────────────────── */

/* The hottest verb in the package: a lexer asks it once per token, where every
 * other verb here is asked once per text. */
static PyObject *verb_munch_scan(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 6) < 0) return NULL;
  size_t munch, at, pick, seated;
  if (as_size(IRGX_ARG(0), &munch) < 0 || as_size(IRGX_ARG(2), &at) < 0 ||
      as_size(IRGX_ARG(4), &pick) < 0 || as_size(IRGX_ARG(5), &seated) < 0)
    return NULL;
  PyObject *permitted = IRGX_ARG(3);

  uint32_t allow_inln[INLINE_ROWS];
  uint32_t *allow = NULL;
  void *allow_heap = NULL;
  size_t nallow = 0;
  if (permitted != Py_None) {
    if (!PyTuple_Check(permitted)) {
      PyErr_SetString(PyExc_TypeError, "allow must be a tuple of pattern indices, or None");
      return NULL;
    }
    Py_ssize_t count = PyTuple_Size(permitted);
    if (widen((size_t)count, sizeof(uint32_t), allow_inln, &allow_heap, (void **)&allow) < 0)
      return NULL;
    for (Py_ssize_t i = 0; i < count; i++) {
      size_t one;
      if (as_size(PyTuple_GetItem(permitted, i), &one) < 0) {
        PyMem_Free(allow_heap);
        return NULL;
      }
      allow[i] = (uint32_t)one;
    }
    nallow = (size_t)count;
  }

  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) {
    PyMem_Free(allow_heap);
    return NULL;
  }
  uint32_t win_inln[INLINE_ROWS];
  uint32_t *win = NULL;
  void *win_heap = NULL;
  if (widen(seated, sizeof(uint32_t), win_inln, &win_heap, (void **)&win) < 0) {
    subject_done(&s);
    PyMem_Free(allow_heap);
    return NULL;
  }
  irgx_munch_token tok = {0, 0};
  int32_t status;
  IRGX_RUN(s, status,
           engine.munch_scan((void *)munch, s.bytes, (size_t)s.len, at, allow, nallow,
                             (uint32_t)pick, &tok, win, seated));
  subject_done(&s);
  PyMem_Free(allow_heap);
  if (status != 1) {
    PyMem_Free(win_heap);
    return refused(status);
  }
  /* `count` is how many patterns reached `len` whether or not the winner buffer
   * held them; sizing at the seated count is what makes overflow unreachable
   * rather than merely unlikely, so this clamps and never retries. */
  size_t rows = tok.count < seated ? tok.count : seated;
  PyObject *winners = PyTuple_New((Py_ssize_t)rows);
  if (winners == NULL) {
    PyMem_Free(win_heap);
    return NULL;
  }
  for (size_t i = 0; i < rows; i++) {
    PyObject *item = PyLong_FromUnsignedLong(win[i]);
    if (item == NULL) {
      Py_DECREF(winners);
      PyMem_Free(win_heap);
      return NULL;
    }
    PyTuple_SetItem(winners, (Py_ssize_t)i, item); /* steals */
  }
  PyMem_Free(win_heap);
  PyObject *reach = PyLong_FromSize_t(tok.len);
  PyObject *found = reach == NULL ? NULL : PyTuple_New(2);
  if (found == NULL) {
    Py_XDECREF(reach);
    Py_DECREF(winners);
    return NULL;
  }
  PyTuple_SetItem(found, 0, reach); /* steals */
  PyTuple_SetItem(found, 1, winners);
  return found;
}

/* ── the literal plane ─────────────────────────────────────────────────── */

static PyObject *verb_needles_is_match(PyObject *self, IRGX_ARGS) {
  (void)self;
  return present(engine.needles_is_match, IRGX_PASS);
}

static PyObject *verb_needles_which(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 3) < 0) return NULL;
  size_t needles, cap;
  if (as_size(IRGX_ARG(0), &needles) < 0 || as_size(IRGX_ARG(2), &cap) < 0) return NULL;
  return indices_of(engine.needles_which, needles, IRGX_ARG(1), cap);
}

/* Occurrences as (needle, start, end), unbounded in the length of the text - so
 * this is the one attribution verb that has to size its own retry. */
static PyObject *verb_needles_find_all(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 2) < 0) return NULL;
  size_t needles;
  if (as_size(IRGX_ARG(0), &needles) < 0) return NULL;
  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;

  irgx_occurrence inln[INLINE_ROWS];
  irgx_occurrence *out = NULL;
  void *heap = NULL;
  size_t cap = first_window((size_t)s.len + 1), written = 0;
  int32_t status;
  if (widen(cap, sizeof(irgx_occurrence), inln, &heap, (void **)&out) < 0) {
    subject_done(&s);
    return NULL;
  }
  IRGX_RUN(s, status,
           engine.needles_find_all((void *)needles, s.bytes, (size_t)s.len, out, cap, &written));
  if (status >= 0 && written > cap) {
    cap = written;
    if (widen(cap, sizeof(irgx_occurrence), inln, &heap, (void **)&out) < 0) {
      subject_done(&s);
      return NULL;
    }
    IRGX_RUN(s, status,
             engine.needles_find_all((void *)needles, s.bytes, (size_t)s.len, out, cap, &written));
  }
  subject_done(&s);
  if (status < 0) {
    PyMem_Free(heap);
    return refused(status);
  }
  size_t rows = written < cap ? written : cap;
  PyObject *list = PyList_New((Py_ssize_t)rows);
  if (list == NULL) {
    PyMem_Free(heap);
    return NULL;
  }
  for (size_t i = 0; i < rows; i++) {
    PyObject *row = PyTuple_New(3);
    PyObject *who = PyLong_FromUnsignedLong(out[i].needle);
    PyObject *from = PyLong_FromSize_t(out[i].start);
    PyObject *to = PyLong_FromSize_t(out[i].end);
    if (row == NULL || who == NULL || from == NULL || to == NULL) {
      Py_XDECREF(row);
      Py_XDECREF(who);
      Py_XDECREF(from);
      Py_XDECREF(to);
      Py_DECREF(list);
      PyMem_Free(heap);
      return NULL;
    }
    PyTuple_SetItem(row, 0, who); /* steals */
    PyTuple_SetItem(row, 1, from);
    PyTuple_SetItem(row, 2, to);
    PyList_SetItem(list, (Py_ssize_t)i, row); /* steals */
  }
  PyMem_Free(heap);
  return list;
}

/* ── binding ───────────────────────────────────────────────────────────── */

/* Take whatever engine symbols the ctypes layer has resolved so far.
 *
 * Called from `irgx._abi.declare`, which is the one place every plane's
 * prototypes are registered - so a plane imported later brings its own symbols
 * with it, and this module never has to know which planes exist or in what
 * order they load. Unknown symbols are ignored rather than refused: `declare`
 * hands over the whole ABI and only ten of it is hot. */
static PyObject *verb_bind(PyObject *self, PyObject *mapping) {
  (void)self;
  if (!PyDict_Check(mapping)) {
    PyErr_SetString(PyExc_TypeError, "bind() takes a dict of {symbol: address}");
    return NULL;
  }
  for (size_t i = 0; i < VERBS; i++) {
    PyObject *found = PyDict_GetItemString(mapping, table[i].symbol);
    if (found == NULL) continue;
    size_t address;
    if (as_size(found, &address) < 0) return NULL;
    if (address == 0) continue;
    void *fn = (void *)address;
    memcpy((char *)&engine + table[i].slot, &fn, sizeof fn);
    is_bound[i] = 1;
  }
  Py_RETURN_NONE;
}

/* Which verbs are live, under the names this module exports them by. Python
 * routes on this and nothing else, so an engine missing a plane degrades to
 * ctypes for that plane alone. */
static PyObject *verb_bound(PyObject *self, PyObject *unused) {
  (void)self;
  (void)unused;
  Py_ssize_t live = 0;
  for (size_t i = 0; i < VERBS; i++) live += is_bound[i] ? 1 : 0;
  PyObject *out = PyTuple_New(live);
  if (out == NULL) return NULL;
  Py_ssize_t at = 0;
  for (size_t i = 0; i < VERBS; i++) {
    if (!is_bound[i]) continue;
    PyObject *name = PyUnicode_FromString(table[i].verb);
    if (name == NULL) {
      Py_DECREF(out);
      return NULL;
    }
    PyTuple_SetItem(out, at++, name); /* steals */
  }
  return out;
}

static PyMethodDef methods[] = {
    {"bind", verb_bind, METH_O, "bind({symbol: address}) - adopt engine function pointers."},
    {"bound", verb_bound, METH_NOARGS, "The verbs this accelerator can currently answer."},
    {"is_match", IRGX_VERB(verb_is_match), IRGX_CALL, "is_match(regex, text, from) -> status"},
    {"find_all", IRGX_VERB(verb_find_all), IRGX_CALL, "find_all(regex, text, from, limit) -> spans | status"},
    {"find_first", IRGX_VERB(verb_find_first), IRGX_CALL, "find_first(regex, text, from) -> span | status"},
    {"captures", IRGX_VERB(verb_captures), IRGX_CALL, "captures(regex, text, at, groups) -> spans | status"},
    {"texts", IRGX_VERB(verb_texts), IRGX_CALL, "texts(regex, text, from, decode) -> [text] | status"},
    {"group_texts", IRGX_VERB(verb_group_texts), IRGX_CALL,
     "group_texts(regex, text, from, count, decode) -> [text | tuple] | status"},
    {"slate_is_match", IRGX_VERB(verb_slate_is_match), IRGX_CALL, "slate_is_match(slate, text) -> status"},
    {"slate_which", IRGX_VERB(verb_slate_which), IRGX_CALL, "slate_which(slate, text, cap) -> [i] | status"},
    {"munch_scan", IRGX_VERB(verb_munch_scan), IRGX_CALL,
     "munch_scan(munch, text, at, allow, pick, seated) -> (reach, winners) | status"},
    {"needles_is_match", IRGX_VERB(verb_needles_is_match), IRGX_CALL,
     "needles_is_match(needles, text) -> status"},
    {"needles_which", IRGX_VERB(verb_needles_which), IRGX_CALL,
     "needles_which(needles, text, cap) -> [i] | status"},
    {"needles_find_all", IRGX_VERB(verb_needles_find_all), IRGX_CALL,
     "needles_find_all(needles, text) -> [(needle, start, end)] | status"},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef accel = {
    PyModuleDef_HEAD_INIT,
    "irgx._accel",
    "Native fast paths for the verbs irregex crosses once per text.",
    -1,
    methods,
    NULL,
    NULL,
    NULL,
    NULL,
};

PyMODINIT_FUNC PyInit__accel(void) { return PyModule_Create(&accel); }
