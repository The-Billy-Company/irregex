// vscan — the Vectorscan (Hyperscan) competitor for the multi-pattern race.
//
// Hyperscan is the reference for simultaneous multi-pattern matching with
// expression-ID attribution: compile N expressions into one automaton, stream
// the bytes once, report every match with the id that produced it. Vectorscan
// (VectorCamp) is the maintained portable fork with NEON/SVE backends, which is
// what runs on this arm64 machine. This program is its fairest possible arm.
//
// Two modes, matching the two races Layer K runs:
//
//   --corpus DIR   per-byte throughput. corpus.bin is already in RAM before the
//                  clock starts; only the scan loop is timed. One `hs_scan` per
//                  document, so the answer shape is gist's `docMask` exactly:
//                  "which pattern ids matched this document".
//   --paths FILE   end-to-end. Read every file from disk and scan it — what a
//                  stream scanner must do to answer a corpus-wide question,
//                  because it has no index to elide a read with.
//
// HS_FLAG_SINGLEMATCH is on: a pattern reports at most once per scan, which is
// precisely per-document attribution and is also Hyperscan's own fastest posture
// for this question (it retires an expression as soon as it fires). Literal
// slates go through `hs_compile_lit_multi` so `-F` semantics are native rather
// than an escaping approximation.
//
// Output is one JSON object on stdout, with a per-pattern document-hit vector so
// the harness can prove attribution equality against gist rather than trust it.
//
// Build: cc -O3 vscan.c -o vscan $(pkg-config --cflags --libs libhs)

// Distributions disagree on the include root: pkg-config's `libhs` points at
// `…/include/hs`, while a source install leaves the headers a level up.
#if __has_include(<hs.h>)
#include <hs.h>
#else
#include <hs/hs.h>
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The sweep runs to N=1024 to show where each strategy belongs (the dragnet's
   cliff, the trawl's flat curve, and Vectorscan's own decay), so the ceiling has
   to clear it rather than fail the top row. */
#define MAX_PATTERNS 2048

struct doc {
    size_t off, len;
};

// Per-scan state handed to the match callback. `seen` is the attribution
// bitmap for the document currently under the scan head.
struct sink {
    uint8_t *seen;
    unsigned n;
    unsigned live; // patterns not yet fired in this document
};

static int on_match(unsigned id, unsigned long long from, unsigned long long to,
                    unsigned flags, void *ctx) {
    (void)from;
    (void)to;
    (void)flags;
    struct sink *s = ctx;
    if (id < s->n && !s->seen[id]) {
        s->seen[id] = 1;
        // Halt the scan once every expression has reported: the question is
        // which patterns match, and no further byte can change that answer.
        // (Hyperscan's own SINGLEMATCH retirement, taken to its conclusion.)
        if (--s->live == 0) return 1;
    }
    return 0;
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static char *slurp(const char *path, size_t *out_len) {
    FILE *fh = fopen(path, "rb");
    if (!fh) return NULL;
    fseek(fh, 0, SEEK_END);
    long n = ftell(fh);
    fseek(fh, 0, SEEK_SET);
    if (n < 0) {
        fclose(fh);
        return NULL;
    }
    char *buf = malloc((size_t)n + 1);
    if (!buf) {
        fclose(fh);
        return NULL;
    }
    size_t got = fread(buf, 1, (size_t)n, fh);
    fclose(fh);
    buf[got] = 0;
    *out_len = got;
    return buf;
}

static void usage(void) {
    fprintf(stderr,
            "usage: vscan (--corpus DIR | --paths FILE) [-F] [-i] -e PATTERN [-e PATTERN...]\n");
    exit(2);
}

int main(int argc, char **argv) {
    const char *pats[MAX_PATTERNS];
    unsigned npat = 0;
    const char *corpus_dir = NULL, *paths_file = NULL;
    int fixed = 0, icase = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-e") && i + 1 < argc) {
            if (npat == MAX_PATTERNS) usage();
            pats[npat++] = argv[++i];
        } else if (!strcmp(argv[i], "--corpus") && i + 1 < argc) {
            corpus_dir = argv[++i];
        } else if (!strcmp(argv[i], "--paths") && i + 1 < argc) {
            paths_file = argv[++i];
        } else if (!strcmp(argv[i], "-F")) {
            fixed = 1;
        } else if (!strcmp(argv[i], "-i")) {
            icase = 1;
        } else {
            usage();
        }
    }
    if (!npat || (!corpus_dir && !paths_file)) usage();

    // ── compile the whole slate into one automaton ───────────────────────────
    unsigned flags[MAX_PATTERNS], ids[MAX_PATTERNS];
    size_t lens[MAX_PATTERNS];
    for (unsigned i = 0; i < npat; i++) {
        flags[i] = HS_FLAG_SINGLEMATCH | (icase ? HS_FLAG_CASELESS : 0);
        ids[i] = i;
        lens[i] = strlen(pats[i]);
    }
    hs_database_t *db = NULL;
    hs_compile_error_t *cerr = NULL;
    double t_compile = now_s();
    hs_error_t rc = fixed
                        ? hs_compile_lit_multi(pats, flags, ids, lens, npat, HS_MODE_BLOCK, NULL,
                                               &db, &cerr)
                        : hs_compile_multi(pats, flags, ids, npat, HS_MODE_BLOCK, NULL, &db, &cerr);
    double compile_s = now_s() - t_compile;
    if (rc != HS_SUCCESS) {
        fprintf(stderr, "vscan: compile failed: %s\n", cerr ? cerr->message : "?");
        if (cerr) hs_free_compile_error(cerr);
        return 3;
    }
    hs_scratch_t *scratch = NULL;
    if (hs_alloc_scratch(db, &scratch) != HS_SUCCESS) {
        fprintf(stderr, "vscan: scratch alloc failed\n");
        return 3;
    }

    uint8_t *hits = calloc(npat, 1);       // per-document scratch
    uint64_t *doc_hits = calloc(npat, 8);  // documents each pattern matched
    struct sink sink = {.seen = hits, .n = npat, .live = npat};

    size_t total_bytes = 0, ndocs = 0;
    double elapsed = 0.0;

    if (corpus_dir) {
        // ── arm 1: per-byte throughput over an already-resident blob ─────────
        char bin[4096], idx[4096];
        snprintf(bin, sizeof bin, "%s/corpus.bin", corpus_dir);
        snprintf(idx, sizeof idx, "%s/corpus.idx", corpus_dir);
        size_t blob_len = 0, idx_len = 0;
        char *blob = slurp(bin, &blob_len);
        char *index = slurp(idx, &idx_len);
        if (!blob || !index) {
            fprintf(stderr, "vscan: cannot read %s / %s\n", bin, idx);
            return 4;
        }
        size_t cap = 1024, n = 0;
        struct doc *docs = malloc(cap * sizeof *docs);
        for (char *line = strtok(index, "\n"); line; line = strtok(NULL, "\n")) {
            unsigned long long off, len;
            if (sscanf(line, "%llu\t%llu", &off, &len) != 2) continue;
            if (n == cap) docs = realloc(docs, (cap *= 2) * sizeof *docs);
            docs[n].off = (size_t)off;
            docs[n].len = (size_t)len;
            n++;
        }
        double t0 = now_s();
        for (size_t d = 0; d < n; d++) {
            memset(hits, 0, npat);
            sink.live = npat;
            hs_scan(db, blob + docs[d].off, (unsigned)docs[d].len, 0, scratch, on_match, &sink);
            for (unsigned p = 0; p < npat; p++) doc_hits[p] += hits[p];
            total_bytes += docs[d].len;
        }
        elapsed = now_s() - t0;
        ndocs = n;
    } else {
        // ── arm 2: end-to-end, the read a scanner cannot elide ───────────────
        size_t list_len = 0;
        char *list = slurp(paths_file, &list_len);
        if (!list) {
            fprintf(stderr, "vscan: cannot read %s\n", paths_file);
            return 4;
        }
        double t0 = now_s();
        char *save = NULL;
        for (char *line = strtok_r(list, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
            if (!*line) continue;
            size_t len = 0;
            char *body = slurp(line, &len);
            if (!body) continue;
            if (memchr(body, 0, len < 8192 ? len : 8192)) { // implicit-binary skip
                free(body);
                continue;
            }
            memset(hits, 0, npat);
            sink.live = npat;
            hs_scan(db, body, (unsigned)len, 0, scratch, on_match, &sink);
            for (unsigned p = 0; p < npat; p++) doc_hits[p] += hits[p];
            total_bytes += len;
            ndocs++;
            free(body);
        }
        elapsed = now_s() - t0;
    }

    printf("{\"tool\":\"vectorscan\",\"version\":\"%s\",\"patterns\":%u,\"docs\":%zu,"
           "\"bytes\":%zu,\"scan_s\":%.6f,\"compile_s\":%.6f,\"gbps\":%.4f,\"doc_hits\":[",
           hs_version(), npat, ndocs, total_bytes, elapsed, compile_s,
           elapsed > 0 ? (double)total_bytes / elapsed / 1e9 : 0.0);
    for (unsigned p = 0; p < npat; p++) printf(p ? ",%llu" : "%llu", (unsigned long long)doc_hits[p]);
    printf("]}\n");

    free(hits);
    free(doc_hits);
    hs_free_scratch(scratch);
    hs_free_database(db);
    return 0;
}
