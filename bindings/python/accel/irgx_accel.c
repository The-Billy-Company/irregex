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
    {"spliced", "irgx_find_all_in", offsetof(struct engine_table, find_all_in)},
    {"pieces", "irgx_find_all_in", offsetof(struct engine_table, find_all_in)},
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

/* Whether a kept span is one this answer stops before. Spelled once because
 * `spliced` walks its spans twice - to size the answer and then to fill it -
 * and the two passes have to stop in the same place or the second overruns the
 * buffer the first measured. */
#define TAKEN(i, limit, done) (!(limit) || (done) < (limit))

/* The gap between the last cut and this span, as Python's own slice would read
 * it. `find_all` answers ascending non-overlapping spans, so a span starting
 * before the cut is unreachable - but a size_t subtraction that wrapped would
 * be a buffer overrun rather than a wrong answer, and `data[cut:at]` is empty
 * there, so the floor is both the safe reading and the faithful one. */
static size_t gap_at(int64_t start, size_t cut) {
  return (size_t)start > cut ? (size_t)start - cut : 0;
}

/* `sub` with a constant replacement, as one crossing: the walk, the thinning,
 * every piece and the join, with the answer sized before it is built so the
 * whole substitution is one allocation.
 *
 * The pieces are cut out of the subject's own UTF-8 and the result is decoded
 * once at the end, which is the same `str` as decoding each piece and joining
 * them - every cut sits on a character boundary, which is exactly what the
 * thinning guarantees. So this verb never needs a byte-to-character
 * translation, and neither does its caller: there is no index in the answer. */
static PyObject *verb_spliced(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 5) < 0) return NULL;
  size_t rx, limit;
  if (as_size(IRGX_ARG(0), &rx) < 0 || as_size(IRGX_ARG(3), &limit) < 0) return NULL;
  int decode = PyObject_IsTrue(IRGX_ARG(4));
  if (decode < 0) return NULL;
  subject s, blade;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;
  if (subject_of(IRGX_ARG(2), &blade) < 0) {
    subject_done(&s);
    return NULL;
  }

  irgx_span inln[INLINE_ROWS];
  irgx_span *out = NULL;
  void *heap = NULL;
  size_t rows = 0;
  int32_t status = walk_spans(rx, &s, 0, 0, inln, &heap, &out, &rows);
  if (status == WALK_PYERR || status < 0) {
    subject_done(&s);
    subject_done(&blade);
    PyMem_Free(heap);
    return status == WALK_PYERR ? NULL : refused(status);
  }

  size_t width = (size_t)blade.len;
  size_t total = 0, cut = 0, made = 0;
  for (size_t i = 0; i < rows && TAKEN(i, limit, made); i++) {
    if (mid_character(&s, out[i].start, decode)) continue;
    size_t grew = gap_at(out[i].start, cut) + width;
    if (total + grew < total) {
      subject_done(&s);
      subject_done(&blade);
      PyMem_Free(heap);
      return PyErr_NoMemory();
    }
    total += grew;
    cut = (size_t)out[i].end;
    made++;
  }
  total += (size_t)s.len - cut;

  /* A bytes answer is written straight into its final object; a str one needs a
   * contiguous UTF-8 run to decode from, and the limited API offers no way to
   * fill a str in place, so that arm pays one scratch buffer. */
  PyObject *owner = NULL;
  char *buf = NULL;
  if (decode) {
    buf = PyMem_Malloc(total + 1);
    if (buf == NULL) PyErr_NoMemory();
  } else if ((owner = PyBytes_FromStringAndSize(NULL, (Py_ssize_t)total)) != NULL) {
    buf = PyBytes_AsString(owner);
  }
  if (buf == NULL) {
    subject_done(&s);
    subject_done(&blade);
    PyMem_Free(heap);
    Py_XDECREF(owner);
    return NULL;
  }

  size_t at = 0, done = 0;
  cut = 0;
  for (size_t i = 0; i < rows && TAKEN(i, limit, done); i++) {
    if (mid_character(&s, out[i].start, decode)) continue;
    size_t gap = gap_at(out[i].start, cut);
    memcpy(buf + at, s.bytes + cut, gap);
    at += gap;
    memcpy(buf + at, blade.bytes, width);
    at += width;
    cut = (size_t)out[i].end;
    done++;
  }
  memcpy(buf + at, s.bytes + cut, (size_t)s.len - cut);

  if (decode) {
    owner = PyUnicode_FromStringAndSize(buf, (Py_ssize_t)total);
    PyMem_Free(buf);
  }
  subject_done(&s);
  subject_done(&blade);
  PyMem_Free(heap);
  if (owner == NULL) return NULL;

  /* (text, made) - `subn` owes the tally, and `sub` drops it. */
  PyObject *answer = PyTuple_New(2);
  PyObject *tally = PyLong_FromSize_t(made);
  if (answer == NULL || tally == NULL) {
    Py_XDECREF(answer);
    Py_XDECREF(tally);
    Py_DECREF(owner);
    return NULL;
  }
  PyTuple_SetItem(answer, 0, owner); /* steals */
  PyTuple_SetItem(answer, 1, tally);
  return answer;
}

/* `split` with no groups, as one crossing: every piece between the matches,
 * finished, in the caller's own type. Same thinning and the same cuts as
 * `spliced`, which is why the two read alike - one joins the pieces and one
 * hands them back. */
static PyObject *verb_pieces(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 4) < 0) return NULL;
  size_t rx, limit;
  if (as_size(IRGX_ARG(0), &rx) < 0 || as_size(IRGX_ARG(2), &limit) < 0) return NULL;
  int decode = PyObject_IsTrue(IRGX_ARG(3));
  if (decode < 0) return NULL;
  subject s;
  if (subject_of(IRGX_ARG(1), &s) < 0) return NULL;

  irgx_span inln[INLINE_ROWS];
  irgx_span *out = NULL;
  void *heap = NULL;
  size_t rows = 0;
  PyObject *list = NULL;
  int32_t status = walk_spans(rx, &s, 0, 0, inln, &heap, &out, &rows);
  if (status == WALK_PYERR || status < 0) {
    subject_done(&s);
    PyMem_Free(heap);
    return status == WALK_PYERR ? NULL : refused(status);
  }

  size_t taken = 0;
  for (size_t i = 0; i < rows && TAKEN(i, limit, taken); i++)
    if (!mid_character(&s, out[i].start, decode)) taken++;
  /* One more piece than there are cuts: the tail after the last match, which
   * is the whole subject when there was none. */
  list = PyList_New((Py_ssize_t)taken + 1);
  if (list == NULL) goto fail;

  size_t cut = 0, done = 0;
  for (size_t i = 0; i < rows && TAKEN(i, limit, done); i++) {
    if (mid_character(&s, out[i].start, decode)) continue;
    PyObject *piece =
        text_of(&s, (int64_t)cut, (int64_t)(cut + gap_at(out[i].start, cut)), decode);
    if (piece == NULL) goto fail;
    PyList_SetItem(list, (Py_ssize_t)done++, piece); /* steals */
    cut = (size_t)out[i].end;
  }
  PyObject *tail = text_of(&s, (int64_t)cut, s.len, decode);
  if (tail == NULL) goto fail;
  PyList_SetItem(list, (Py_ssize_t)taken, tail); /* steals */
  subject_done(&s);
  PyMem_Free(heap);
  return list;

fail:
  subject_done(&s);
  PyMem_Free(heap);
  Py_XDECREF(list);
  return NULL;
}

/* ── Match, as a C type ────────────────────────────────────────────────── */

/* A match is the one object this binding mints per *result* rather than per
 * call, so a walk over a page of prose builds hundreds of them and everything
 * about them is hot. In Python the object cost more than the search did: a
 * `TextView` and a `Match` by attribute assignment is 146 ns before anybody asks
 * a question, and `.span()` on the built object another 50 - so `search().span()`
 * spent 323 ns wrapping an 80 ns engine call, against `re`'s 96 ns for both.
 *
 * The split here is deliberate and narrow. This type owns the storage, the
 * construction, and the accessors for the case that is nearly every case: an
 * integer group on a subject whose two domains coincide (`bytes`, or a `str`
 * whose UTF-8 is all ASCII). Everything else - a group NAME, an out-of-range or
 * non-integer group, a non-ASCII `str`, a pattern whose capture arm refused -
 * declines to the Python implementation, which is unchanged and remains the only
 * statement of those rules. That is why the five private attributes below are
 * exposed under exactly the names the Python methods already read: those method
 * bodies work verbatim against this storage, so the harder half of `Match` has
 * one implementation rather than two.
 *
 * Two fields are lazy for the same reason and it is the same reason the split
 * above pays: `caps` is the capture pass, and `view` is the `TextView` that
 * translates offsets. A `finditer` over a pattern with groups, iterated purely
 * to count hits, asks for neither - so neither is built at construction, and the
 * narrow arm never builds a view at all. */
typedef struct {
  PyObject_HEAD
  PyObject *re;   /* the Pattern that produced this match */
  PyObject *text; /* the subject, exactly the object the caller passed */
  PyObject *view; /* a TextView, once a caller reaches the translating arm */
  PyObject *caps; /* the capture pass as Python spans, once anybody asks */
  Py_ssize_t start;
  Py_ssize_t end;
  int wide; /* the caller's domain and the engine's differ */
} MatchObj;

/* This type is not subclassed. `irgx._match` attaches the Python half's methods
 * straight onto it, which a type built by `PyType_FromSpec` permits because it is
 * a heap type and therefore mutable - and that is a decision rather than a
 * convenience. A Python subclass of a heap type routes teardown through
 * `subtype_dealloc`, which releases the subclass's own reference on its type, so
 * a base `tp_dealloc` that also released one would be a double decref of the
 * class. One class means one owner. It also means a caller's `type(m)` is
 * `irgx.Match` with nothing private underneath it, and that `Match` is the same
 * name on both transports rather than a base and a subclass on one of them.
 *
 * `TextView` is the one Python object this file cannot make for itself, and it
 * arrives at import rather than by import: a C module reaching back into its own
 * package would fix an import order the package is entitled to choose. */
static PyObject *view_type = NULL;

/* `Py_XSETREF` in the limited API, which does not export it: replace a slot,
 * releasing what was there only after the new value is in place, so a
 * deallocator that reaches this object cannot see a dangling one. */
static void set_ref(PyObject **slot, PyObject *value) {
  PyObject *was = *slot;
  *slot = value;
  Py_XDECREF(was);
}

static int match_init(PyObject *self, PyObject *args, PyObject *kwargs);
static int span_reading(PyObject *span, Py_ssize_t *start, Py_ssize_t *end);
static PyObject *match_item(PyObject *self, PyObject *group);

/* Every name this file reaches into the Python arm by, interned once at first
 * ask. `PyObject_GetAttrString` mints a fresh `str` on every call, which on a
 * method that declines is a measurable share of the whole answer. */
enum {
  NAME_SLOW_SPAN,
  NAME_SLOW_START,
  NAME_SLOW_END,
  NAME_SLOW_TEXT,
  NAME_SLOW_GROUP,
  NAME_SLOW_GROUPS,
  NAME_CAPTURES_AT,
  NAME_SEARCHED,
  NAME_DECLARED,
  NAME_COUNT
};

static const char *const name_says[NAME_COUNT] = {
    "_slow_span", "_slow_start",  "_slow_end", "_slow_text", "_slow_group",
    "_slow_groups", "_captures_at", "searched",  "_groups",
};

static PyObject *names[NAME_COUNT];

static PyObject *named(int which) {
  PyObject *said = names[which];
  if (said == NULL) said = names[which] = PyUnicode_InternFromString(name_says[which]);
  return said;
}

static void match_dealloc(PyObject *self) {
  MatchObj *m = (MatchObj *)self;
  PyTypeObject *kind = Py_TYPE(self);
  Py_CLEAR(m->re);
  Py_CLEAR(m->text);
  Py_CLEAR(m->view);
  Py_CLEAR(m->caps);
  freefunc release = (freefunc)PyType_GetSlot(kind, Py_tp_free);
  if (release != NULL) release(self);
  /* A heap type holds a reference on each of its instances, so the type dies
   * with the last one rather than at module teardown. */
  Py_DECREF((PyObject *)kind);
}

/* The capture pass's answer for this match, resolved on the first ask and held
 * after. Borrowed reference.
 *
 * The pass itself stays the Python arm's, called by its own name: what a
 * refusing capture engine means, and the cross-check that catches the two arms
 * reporting different whole-matches, are rules and this file states none. What
 * is here is the holding, and the one argument the rule needs - the text the
 * whole-match pass actually ran against. A view carries that as `searched`,
 * which is a cut of the caller's object when an `endpos` bounded the search; a
 * match from the unbounded fast paths has no view at all, and there the
 * caller's own object is what was searched. Reading it this way is what lets
 * this arm resolve captures without first building a view it has no other use
 * for. */
static PyObject *match_caps(MatchObj *m) {
  if (m->caps != NULL) return m->caps;
  PyObject *searched = m->view == NULL ? Py_NewRef(m->text)
                                      : PyObject_GetAttr(m->view, named(NAME_SEARCHED));
  if (searched == NULL) return NULL;
  PyObject *fn = PyObject_GetAttr(m->re, named(NAME_CAPTURES_AT));
  PyObject *from = fn == NULL ? NULL : PyLong_FromSsize_t(m->start);
  PyObject *to = from == NULL ? NULL : PyLong_FromSsize_t(m->end);
  PyObject *out =
      to == NULL ? NULL : PyObject_CallFunctionObjArgs(fn, searched, from, to, NULL);
  Py_XDECREF(to);
  Py_XDECREF(from);
  Py_XDECREF(fn);
  Py_DECREF(searched);
  if (out == NULL) return NULL;
  set_ref(&m->caps, out); /* steals the reference the call returned */
  return m->caps;
}

/* One group's byte span, when this arm can read it: the whole match, or a
 * declared group the match entered, on a subject whose two domains coincide.
 * 1 is answered, 0 is "not mine", -1 is an error already set - and this is the
 * ONLY place that boundary is drawn.
 *
 * Everything it declines, it declines because the answer is a rule this file
 * does not state: a name or a non-integer (whose TypeError has wording), an
 * out-of-range group or a pattern whose capture arm refused (likewise), a group
 * the match never entered (where `group` says `None`, `span` says `(-1, -1)`
 * and `start` says `-1`, so the answer is per-method), and a wide subject
 * (where a byte offset is not a character index and translating is the one
 * thing `TextView` exists for).
 *
 * Group 0 is answered before the capture pass is ever asked for, which is what
 * keeps `m.group()` and `m.span()` working on a pattern whose capture arm
 * refused: `find_all` already reported those offsets.
 *
 * Exact-int and not a subclass, for two separate reasons that both matter:
 * `True` means group 1 to `re` and would read as truthy-nonzero here, and `0.0`
 * must still reach the Python arm to be the TypeError it already is. */
static int group_span(MatchObj *m, PyObject *group, Py_ssize_t *from, Py_ssize_t *to) {
  if (m->wide) return 0;
  /* NULL is "no argument", which means group 0. An explicit `None` is not the
   * same thing and is a TypeError the Python arm phrases. */
  if (group == NULL) {
    *from = m->start;
    *to = m->end;
    return 1;
  }
  if (!PyLong_CheckExact(group)) return 0;
  Py_ssize_t want = PyLong_AsSsize_t(group);
  if (want == -1 && PyErr_Occurred()) {
    PyErr_Clear(); /* an int too large to be a group is still the Python arm's */
    return 0;
  }
  if (want == 0) {
    *from = m->start;
    *to = m->end;
    return 1;
  }
  if (want < 0) return 0;

  /* The range check reads the pattern's own count, in the order the Python arm
   * reads it: a refusing arm (`None`) is its error to raise before any
   * out-of-range one, so both leave here as the same refusal. */
  PyObject *declared = PyObject_GetAttr(m->re, named(NAME_DECLARED));
  if (declared == NULL) return -1;
  int counted = PyLong_CheckExact(declared);
  Py_ssize_t total = counted ? PyLong_AsSsize_t(declared) : -1;
  Py_DECREF(declared);
  if (!counted || want > total) return 0;

  PyObject *caps = match_caps(m);
  if (caps == NULL) return -1;
  PyObject *span = PySequence_GetItem(caps, want);
  if (span == NULL) return -1;
  int mine = span == Py_None ? 0 : span_reading(span, from, to) < 0 ? -1 : 1;
  Py_DECREF(span);
  return mine;
}

/* One method's worth of "not mine": call the Python implementation by its own
 * name. Those names exist only on the Python half, so there is no route back
 * into here and no recursion.
 *
 * A NULL group is spelled out as 0 rather than left to the callee's default,
 * because the five methods behind this do not all have one - `_text_of` takes
 * its group positionally. Saying it once here is also the honest statement:
 * "no argument" and "group 0" are the same request. */
static PyObject *match_decline(PyObject *self, int name, PyObject *arg) {
  PyObject *fn = PyObject_GetAttr(self, named(name));
  if (fn == NULL) return NULL;
  PyObject *which = arg != NULL ? Py_NewRef(arg) : PyLong_FromLong(0);
  PyObject *out = which == NULL ? NULL : PyObject_CallFunctionObjArgs(fn, which, NULL);
  Py_XDECREF(which);
  Py_DECREF(fn);
  return out;
}

/* `span`/`start`/`end`/`group` all take an optional single group, so they share
 * one reading of argv - including the arity refusal, which `re` phrases as a
 * TypeError on too many arguments. */
static int one_group(IRGX_ARGS, PyObject **group) {
  if (IRGX_NARGS > 1) {
    PyErr_Format(PyExc_TypeError, "expected at most 1 argument, got %zd", (Py_ssize_t)IRGX_NARGS);
    return -1;
  }
  *group = IRGX_NARGS == 1 ? IRGX_ARG(0) : NULL;
  return 0;
}

static PyObject *match_slice(const MatchObj *m, Py_ssize_t from, Py_ssize_t to) {
  return PySequence_GetSlice(m->text, from, to);
}

static PyObject *match_span(PyObject *self, IRGX_ARGS) {
  PyObject *group;
  if (one_group(IRGX_PASS, &group) < 0) return NULL;
  Py_ssize_t from, to;
  int mine = group_span((MatchObj *)self, group, &from, &to);
  if (mine < 0) return NULL;
  return mine == 0 ? match_decline(self, NAME_SLOW_SPAN, group) : pair(from, to);
}

static PyObject *match_start(PyObject *self, IRGX_ARGS) {
  PyObject *group;
  if (one_group(IRGX_PASS, &group) < 0) return NULL;
  Py_ssize_t from, to;
  int mine = group_span((MatchObj *)self, group, &from, &to);
  if (mine < 0) return NULL;
  return mine == 0 ? match_decline(self, NAME_SLOW_START, group) : PyLong_FromSsize_t(from);
}

static PyObject *match_end(PyObject *self, IRGX_ARGS) {
  PyObject *group;
  if (one_group(IRGX_PASS, &group) < 0) return NULL;
  Py_ssize_t from, to;
  int mine = group_span((MatchObj *)self, group, &from, &to);
  if (mine < 0) return NULL;
  return mine == 0 ? match_decline(self, NAME_SLOW_END, group) : PyLong_FromSsize_t(to);
}

static PyObject *match_group(PyObject *self, IRGX_ARGS) {
  /* `m.group()` and `m.group(n)` are what almost every caller writes and both
   * want one value; several groups is a tuple, which the Python arm builds from
   * the same `_text_of` this one declines to. */
  if (IRGX_NARGS > 1) {
    PyObject *fn = PyObject_GetAttr(self, named(NAME_SLOW_GROUP));
    if (fn == NULL) return NULL;
    PyObject *many = PyTuple_New(IRGX_NARGS);
    if (many == NULL) {
      Py_DECREF(fn);
      return NULL;
    }
    for (Py_ssize_t i = 0; i < IRGX_NARGS; i++)
      PyTuple_SetItem(many, i, Py_NewRef(IRGX_ARG(i))); /* steals */
    PyObject *out = PyObject_Call(fn, many, NULL);
    Py_DECREF(many);
    Py_DECREF(fn);
    return out;
  }
  PyObject *group = IRGX_NARGS == 1 ? IRGX_ARG(0) : NULL;
  return match_item(self, group);
}

static PyObject *match_item(PyObject *self, PyObject *group) {
  MatchObj *m = (MatchObj *)self;
  Py_ssize_t from, to;
  int mine = group_span(m, group, &from, &to);
  if (mine < 0) return NULL;
  return mine == 0 ? match_decline(self, NAME_SLOW_TEXT, group) : match_slice(m, from, to);
}

/* `groups(default=None)` - every declared group's text.
 *
 * The one cold-looking method that is actually hot, because it is how a caller
 * reads a pattern that has groups at all: `search(...).groups()`. The Python arm
 * spells it as a generator over `_cut`, which is a frame per group plus a span
 * unpack, and the answer on this arm is a tuple of slices of an object this type
 * already holds - measured at four times what the slices themselves cost.
 *
 * The capture pass stays the Python arm's, asked for by its own name: what a
 * refusing capture engine means, and the whole-match cross-check that catches
 * the two arms disagreeing, are rules and this file states none. So this is the
 * loop and nothing above it.
 *
 * `wide` declines outright. A span there is a byte offset and the answer is
 * characters, which is `TextView`'s incremental translation - restating that
 * here would be a second implementation of the one thing the view exists for. */
static PyObject *match_groups(PyObject *self, IRGX_ARGS) {
  if (IRGX_NARGS > 1) {
    PyErr_Format(PyExc_TypeError, "expected at most 1 argument, got %zd", (Py_ssize_t)IRGX_NARGS);
    return NULL;
  }
  MatchObj *m = (MatchObj *)self;
  PyObject *blank = IRGX_NARGS == 1 ? IRGX_ARG(0) : Py_None;
  if (m->wide) return match_decline(self, NAME_SLOW_GROUPS, blank);
  PyObject *spans = match_caps(m);
  if (spans == NULL) return NULL;
  Py_INCREF(spans); /* borrowed from the match, held for the loop below */
  Py_ssize_t rows = PySequence_Size(spans);
  if (rows < 0) {
    Py_DECREF(spans);
    return NULL;
  }
  PyObject *out = PyTuple_New(rows > 0 ? rows - 1 : 0);
  if (out == NULL) {
    Py_DECREF(spans);
    return NULL;
  }
  for (Py_ssize_t g = 1; g < rows; g++) {
    PyObject *span = PySequence_GetItem(spans, g);
    PyObject *item = NULL;
    if (span == NULL) goto fail;
    if (span == Py_None) {
      item = Py_NewRef(blank);
    } else {
      Py_ssize_t from = -1, to = -1;
      PyObject *a = PySequence_GetItem(span, 0);
      PyObject *b = a == NULL ? NULL : PySequence_GetItem(span, 1);
      if (b != NULL) {
        from = PyLong_AsSsize_t(a);
        to = PyLong_AsSsize_t(b);
      }
      Py_XDECREF(a);
      Py_XDECREF(b);
      if (b == NULL || PyErr_Occurred()) goto fail;
      item = match_slice(m, from, to);
    }
    if (item == NULL) goto fail;
    PyTuple_SetItem(out, g - 1, item); /* steals */
    Py_DECREF(span);
    continue;
  fail:
    Py_XDECREF(span);
    Py_DECREF(out);
    Py_DECREF(spans);
    return NULL;
  }
  Py_DECREF(spans);
  return out;
}

/* ── the five private attributes the Python arm reads ──────────────────── */

static PyObject *match_get_re(PyObject *self, void *closure) {
  (void)closure;
  return Py_NewRef(((MatchObj *)self)->re);
}

static PyObject *match_get_string(PyObject *self, void *closure) {
  (void)closure;
  return Py_NewRef(((MatchObj *)self)->text);
}

static PyObject *match_get_start(PyObject *self, void *closure) {
  (void)closure;
  return PyLong_FromSsize_t(((MatchObj *)self)->start);
}

static PyObject *match_get_end(PyObject *self, void *closure) {
  (void)closure;
  return PyLong_FromSsize_t(((MatchObj *)self)->end);
}

/* The `TextView` the Python arm slices and translates through, built on the
 * first ask rather than at construction - on the narrow arm nothing ever asks,
 * which is the whole saving. Built by calling `TextView(text)`, so the view's
 * own rules stay stated once, in Python. */
static PyObject *match_get_view(PyObject *self, void *closure) {
  (void)closure;
  MatchObj *m = (MatchObj *)self;
  if (m->view == NULL) {
    if (view_type == NULL) {
      PyErr_SetString(PyExc_RuntimeError, "the accelerator was never given TextView");
      return NULL;
    }
    m->view = PyObject_CallFunctionObjArgs(view_type, m->text, NULL);
    if (m->view == NULL) return NULL;
  }
  return Py_NewRef(m->view);
}

static PyObject *match_get_spans(PyObject *self, void *closure) {
  (void)closure;
  MatchObj *m = (MatchObj *)self;
  return Py_NewRef(m->caps == NULL ? Py_None : m->caps);
}

static int match_set_spans(PyObject *self, PyObject *value, void *closure) {
  (void)closure;
  MatchObj *m = (MatchObj *)self;
  set_ref(&m->caps, value == NULL || value == Py_None ? NULL : Py_NewRef(value));
  return 0;
}

/* Through the accessors rather than the fields: a wide match's span reads in the
 * caller's domain, and that translation is the Python arm's. */
static PyObject *match_repr(PyObject *self) {
  PyObject *shown = PyObject_CallMethod(self, "group", NULL);
  if (shown == NULL) return NULL;
  PyObject *span = PyObject_CallMethod(self, "span", NULL);
  if (span == NULL) {
    Py_DECREF(shown);
    return NULL;
  }
  PyObject *out = PyUnicode_FromFormat("<irgx.Match object; span=%S, match=%R>", span, shown);
  Py_DECREF(shown);
  Py_DECREF(span);
  return out;
}

static PyMethodDef match_methods[] = {
    {"span", IRGX_VERB(match_span), IRGX_CALL, "span(group=0) -> (start, end)"},
    {"start", IRGX_VERB(match_start), IRGX_CALL, "start(group=0) -> index"},
    {"end", IRGX_VERB(match_end), IRGX_CALL, "end(group=0) -> index"},
    {"group", IRGX_VERB(match_group), IRGX_CALL, "group(*groups) -> text | tuple"},
    {"groups", IRGX_VERB(match_groups), IRGX_CALL, "groups(default=None) -> tuple"},
    {NULL, NULL, 0, NULL},
};

static PyGetSetDef match_getset[] = {
    {"re", match_get_re, NULL, "The pattern that produced this match.", NULL},
    {"string", match_get_string, NULL, "The text that was searched.", NULL},
    {"_re", match_get_re, NULL, NULL, NULL},
    {"_view", match_get_view, NULL, NULL, NULL},
    {"_start", match_get_start, NULL, NULL, NULL},
    {"_end", match_get_end, NULL, NULL, NULL},
    {"_spans", match_get_spans, match_set_spans, NULL, NULL},
    {NULL, NULL, NULL, NULL, NULL},
};

static PyType_Slot match_slots[] = {
    {Py_tp_new, PyType_GenericNew},
    {Py_tp_init, match_init},
    {Py_tp_dealloc, match_dealloc},
    {Py_tp_repr, match_repr},
    {Py_tp_methods, match_methods},
    {Py_tp_getset, match_getset},
    {Py_mp_subscript, match_item},
    {Py_tp_doc, (void *)"One match, reported in the domain of the text that produced it."},
    {0, NULL},
};

/* Named for where it ends up rather than where it is built: `irgx._match`
 * finishes this type and re-exports it as `irgx.Match`, and a caller reading a
 * traceback should see the name they can import. Deliberately not a base type -
 * see the note above `view_type`. */
static PyType_Spec match_spec = {
    .name = "irgx.Match",
    .basicsize = sizeof(MatchObj),
    .flags = Py_TPFLAGS_DEFAULT,
    .slots = match_slots,
};

static PyObject *match_type = NULL;

/* One match, from parts already settled. Every constructor below funnels here,
 * so ownership and the lazy fields are stated once. */
static PyObject *match_make(PyObject *re, PyObject *text, PyObject *view, Py_ssize_t start,
                           Py_ssize_t end, int wide) {
  PyTypeObject *kind = (PyTypeObject *)match_type;
  allocfunc make = (allocfunc)PyType_GetSlot(kind, Py_tp_alloc);
  if (make == NULL) return NULL;
  MatchObj *m = (MatchObj *)make(kind, 0);
  if (m == NULL) return NULL;
  m->re = Py_NewRef(re);
  m->text = Py_NewRef(text);
  m->view = view == NULL ? NULL : Py_NewRef(view);
  m->caps = NULL;
  m->start = start;
  m->end = end;
  m->wide = wide;
  return (PyObject *)m;
}

/* Whether the caller's domain and the engine's differ, from the object rather
 * than from a scan: a `str` is wide exactly when its UTF-8 is longer than its
 * character count. `PyUnicode_GetLength` is O(1) and the UTF-8 was just read by
 * whatever searched it, so this is a comparison where Python's `str.isascii()`
 * is a call over the whole string. */
static int is_wide(PyObject *text) {
  if (!PyUnicode_Check(text)) return 0;
  Py_ssize_t bytes = 0;
  if (PyUnicode_AsUTF8AndSize(text, &bytes) == NULL) return -1;
  return PyUnicode_GetLength(text) != bytes;
}

/* The two facts a `TextView` carries that a match keeps: the caller's own object,
 * and whether the two domains differ. `*text` comes back owned. */
static int view_reading(PyObject *view, PyObject **text) {
  PyObject *original = PyObject_GetAttrString(view, "original");
  if (original == NULL) return -1;
  PyObject *flag = PyObject_GetAttrString(view, "wide");
  if (flag == NULL) {
    Py_DECREF(original);
    return -1;
  }
  int wide = PyObject_IsTrue(flag);
  Py_DECREF(flag);
  if (wide < 0) {
    Py_DECREF(original);
    return -1;
  }
  *text = original;
  return wide;
}

/* `Match(pattern, view, start, end)` - the constructor the Python class states,
 * spelled the same way here so `_anchored` and the scanner call one signature
 * whichever transport is live. A view handed in is kept: a walk shares one
 * across every match it yields, and its checkpoint cache is what keeps a wide
 * `finditer` linear instead of quadratic. */
static int match_init(PyObject *self, PyObject *args, PyObject *kwargs) {
  MatchObj *m = (MatchObj *)self;
  PyObject *re = NULL, *view = NULL;
  Py_ssize_t start = 0, end = 0;
  static char *names[] = {"pattern", "view", "start", "end", NULL};
  if (!PyArg_ParseTupleAndKeywords(args, kwargs, "OOnn:Match", names, &re, &view, &start, &end))
    return -1;
  PyObject *text = NULL;
  int wide = view_reading(view, &text);
  if (wide < 0) return -1;
  set_ref(&m->re, Py_NewRef(re));
  set_ref(&m->text, text); /* the reference `view_reading` handed over */
  set_ref(&m->view, Py_NewRef(view));
  set_ref(&m->caps, NULL);
  m->start = start;
  m->end = end;
  m->wide = wide;
  return 0;
}

/* One span as two indices, refusing anything that is not the shape the seam
 * hands back. */
static int span_reading(PyObject *span, Py_ssize_t *start, Py_ssize_t *end) {
  if (!PyTuple_Check(span) || PyTuple_Size(span) != 2) {
    PyErr_SetString(PyExc_TypeError, "expected a (start, end) span");
    return -1;
  }
  *start = PyLong_AsSsize_t(PyTuple_GetItem(span, 0));
  *end = PyLong_AsSsize_t(PyTuple_GetItem(span, 1));
  return (*start == -1 || *end == -1) && PyErr_Occurred() ? -1 : 0;
}

/* `over(pattern, text, span)` - a match over a subject with no view yet, which
 * is what `search` has after a hit: the view is the object the narrow arm never
 * needs, so not building one is most of what this saves. The span arrives as the
 * tuple the seam returned rather than as two arguments, so the caller unpacks
 * nothing on the way here. */
static PyObject *verb_over(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 3) < 0) return NULL;
  PyObject *text = IRGX_ARG(1);
  Py_ssize_t start = 0, end = 0;
  if (span_reading(IRGX_ARG(2), &start, &end) < 0) return NULL;
  int wide = is_wide(text);
  if (wide < 0) return NULL;
  return match_make(IRGX_ARG(0), text, NULL, start, end, wide);
}

/* `sought(handle, pattern, text)` - the whole of an unbounded `search`, in one
 * crossing.
 *
 * `find_first` followed by `over` answers the same question and costs two
 * crossings, plus the `(start, end)` tuple the first mints only for the second to
 * take apart. Both are pure overhead on the row where this engine looks worst:
 * a literal in a short line, where the scan itself is single-digit nanoseconds
 * and everything else is dispatch. Fusing them is the only lever that removes a
 * crossing rather than making one cheaper, and it is available precisely because
 * the fast path has no view, no bounds and no domain question left to answer -
 * `Pattern.search` settled all three before calling.
 *
 * `wide` is read off the subject already in hand rather than from `is_wide`,
 * which would ask CPython for the same UTF-8 a second time. Both spellings are
 * the same comparison; this one is the one that has the length.
 *
 * A refusal - including no match - comes back as the engine's own status, the
 * convention every other verb here follows, so the sentence it turns into is
 * still written once in `irgx._abi`.
 *
 * Deliberately NOT a row in `table`, and therefore not in `bound()`: what that
 * list means is "seam verbs with a ctypes twin", and this one hands back a
 * `Match` rather than the spans and texts the seam trades in. It is published
 * like `over` and `matches` - a module method the caller selects - and gated on
 * `find_first`, the seam verb it is made of, with the pointer checked here too
 * so the C is honest whatever selects it. */
static PyObject *verb_sought(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 3) < 0) return NULL;
  if (engine.find_first_in == NULL) {
    PyErr_SetString(PyExc_RuntimeError, "this engine does not export irgx_find_first_in");
    return NULL;
  }
  size_t rx;
  if (as_size(IRGX_ARG(0), &rx) < 0) return NULL;
  PyObject *text = IRGX_ARG(2);
  subject s;
  if (subject_of(text, &s) < 0) return NULL;
  size_t n = (size_t)s.len;
  irgx_span span = {0, 0};
  int32_t status;
  IRGX_RUN(s, status, engine.find_first_in((void *)rx, s.bytes, n, 0, n, &span));
  subject_done(&s);
  if (status != 1) return refused(status);
  int wide = PyUnicode_Check(text) && PyUnicode_GetLength(text) != s.len;
  return match_make(IRGX_ARG(1), text, NULL, span.start, span.end, wide);
}

/* `matches(pattern, view, spans)` - every match of one walk, built in one
 * crossing. The Python spelling was `starmap(partial(Match, self, view), found)`,
 * which is a partial, a frame and an `__init__` per match on a list the walk had
 * already finished; here it is one loop. The view is shared, exactly as it was,
 * so a wide walk still translates through one checkpoint cache. */
static PyObject *verb_matches(PyObject *self, IRGX_ARGS) {
  (void)self;
  if (arity(IRGX_NARGS, 3) < 0) return NULL;
  PyObject *re = IRGX_ARG(0), *view = IRGX_ARG(1), *spans = IRGX_ARG(2);
  if (!PyList_Check(spans)) {
    PyErr_SetString(PyExc_TypeError, "matches() takes the walk's own list of spans");
    return NULL;
  }
  PyObject *text = NULL;
  int wide = view_reading(view, &text);
  if (wide < 0) return NULL;

  Py_ssize_t count = PyList_Size(spans);
  PyObject *out = PyList_New(count);
  for (Py_ssize_t i = 0; out != NULL && i < count; i++) {
    PyObject *span = PyList_GetItem(spans, i); /* borrowed */
    Py_ssize_t start = 0, end = 0;
    PyObject *one = span == NULL || span_reading(span, &start, &end) < 0
                        ? NULL
                        : match_make(re, text, view, start, end, wide);
    if (one == NULL) {
      Py_CLEAR(out);
      break;
    }
    PyList_SetItem(out, i, one); /* steals */
  }
  Py_DECREF(text);
  return out;
}

/* Handed over at import rather than imported, and handed the type this module
 * cannot construct: see `view_type`. */
static PyObject *verb_set_view(PyObject *self, PyObject *kind) {
  (void)self;
  set_ref(&view_type, Py_NewRef(kind));
  Py_RETURN_NONE;
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
    {"spliced", IRGX_VERB(verb_spliced), IRGX_CALL,
     "spliced(regex, text, sep, count, decode) -> (text, made) | status"},
    {"pieces", IRGX_VERB(verb_pieces), IRGX_CALL,
     "pieces(regex, text, maxsplit, decode) -> [text] | status"},
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
    {"sought", IRGX_VERB(verb_sought), IRGX_CALL,
     "sought(handle, pattern, text) -> Match | status"},
    {"over", IRGX_VERB(verb_over), IRGX_CALL, "over(pattern, text, span) -> Match"},
    {"matches", IRGX_VERB(verb_matches), IRGX_CALL, "matches(pattern, view, spans) -> [Match]"},
    {"set_view", verb_set_view, METH_O, "set_view(TextView) - the view type this module builds."},
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

PyMODINIT_FUNC PyInit__accel(void) {
  PyObject *mod = PyModule_Create(&accel);
  if (mod == NULL) return NULL;
  /* The type is built here and finished in Python: `irgx._match` grafts the cold
   * methods on and hands back `TextView`. Until it does, `Match` exists and
   * answers the four fast questions - which is what makes the graft a completion
   * rather than a dependency. */
  match_type = PyType_FromSpec(&match_spec);
  if (match_type == NULL || PyModule_AddObjectRef(mod, "Match", match_type) < 0) {
    Py_XDECREF(match_type);
    match_type = NULL;
    Py_DECREF(mod);
    return NULL;
  }
  return mod;
}
