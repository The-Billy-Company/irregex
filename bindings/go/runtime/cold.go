package runtime

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
)

// ErrNoBinary reports that none of the certified binaries could be found, which
// is the one way an answer is genuinely unavailable: with no library and no
// child, there is no engine. Fail closed — a second matcher would be a different
// answer wearing this API's name.
var ErrNoBinary = errors.New("irregex: no gist/relate/blast binary found")

// The three product faces of one kernel, each with an env override so a host can
// pin an exact build ([transports]).
const (
	ToolGist   = "gist"
	ToolRelate = "relate"
	ToolBlast  = "blast"
	// ToolIrregex is the pre-rename name of ToolBlast.
	ToolIrregex = ToolBlast
)

var envOverride = map[string]string{
	ToolGist:   "GIST_BIN",
	ToolRelate: "RELATE_BIN",
	ToolBlast:  "BLAST_BIN",
}

// coldTimeout bounds one child. A corpus-wide kinship sweep on a large tree is
// seconds, not minutes; a caller wanting longer passes a ctx with its own
// deadline, which wins.
const coldTimeout = 60 * time.Second

var (
	resolvedMu sync.Mutex
	resolved   = map[string]resolvedPath{}
)

type resolvedPath struct {
	path string
	err  error
}

// Binary is the absolute path to one of the kernel's product binaries.
// Resolution order is the env override, a built zig-out/bin/<name> in this
// checkout or an ancestor of it, the sibling checkout that owns the name, then
// PATH — checkout-local ahead of PATH so a worktree never drives a stale
// globally installed build. Cached per process, negative answers included: a
// host with no binary asks once, not once per query.
func Binary(name string) (string, error) {
	resolvedMu.Lock()
	defer resolvedMu.Unlock()
	if r, ok := resolved[name]; ok {
		return r.path, r.err
	}
	var r resolvedPath
	r.path, r.err = locate(name)
	resolved[name] = r
	return r.path, r.err
}

func locate(name string) (string, error) {
	if env := os.Getenv(envOverride[name]); env != "" {
		if info, err := os.Stat(env); err == nil && !info.IsDir() {
			return env, nil
		}
		return "", fmt.Errorf("%w: %s=%q is not a file", ErrNoBinary, envOverride[name], env)
	}
	looked := candidates(name)
	for _, bin := range looked {
		if isFile(bin) {
			return bin, nil
		}
	}
	if onPath, err := exec.LookPath(name); err == nil {
		return onPath, nil
	}
	return "", fmt.Errorf("%w: %s is unset, %s is not on PATH, and no build exists at any of:\n\t%s\nbuild one with `zig build -Doptimize=ReleaseFast` in the %s checkout",
		ErrNoBinary, envOverride[name], name, strings.Join(searched(looked), "\n\t"), name)
}

// candidates is the ordered ladder of `zig-out/bin/<name>` paths a local build
// could occupy, discovered by ascending from the working directory. A Go package
// has no __file__, so the tree is found rather than baked in — which also means
// a consumer outside the ecosystem simply falls through to PATH.
//
// Two passes, in the order the Python binding already resolves in
// (bindings/python/irgx/runtime/shell.py, `_locate_root`): an already-built
// binary anywhere up the chain, then the sibling checkout that owns the name.
// The two are describing the same fact about one filesystem, so they must agree.
// The four packages are flat siblings of one workspace — `relate` sits at
// ../relate/zig-out/bin/relate whether the process runs inside irregex or blast
// — and a sibling is only believed when it carries the `build.zig` that makes it
// that package's checkout rather than a directory that happens to share a name.
//
// Own build ahead of sibling on purpose: the checkout you are standing in is the
// one you just rebuilt, and a sibling's zig-out may hold something older. No rung
// dates what it finds, so pin an exact build with the env override when the
// difference matters.
func candidates(name string) []string {
	dir, err := os.Getwd()
	if err != nil {
		return nil
	}
	ancestors := make([]string, 0, 16)
	for range 16 {
		ancestors = append(ancestors, dir)
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	own := make([]string, 0, len(ancestors))
	var siblings []string
	for _, a := range ancestors {
		own = append(own, filepath.Join(a, "zig-out", "bin", name))
		// An ancestor named `name` IS the owning checkout, and its build is
		// already the candidate just appended.
		if filepath.Base(a) == name || !isFile(filepath.Join(a, "build.zig")) {
			continue
		}
		if s := filepath.Join(filepath.Dir(a), name); isFile(filepath.Join(s, "build.zig")) {
			siblings = append(siblings, filepath.Join(s, "zig-out", "bin", name))
		}
	}
	return append(own, siblings...)
}

// searched renders the ladder for a failure. Naming every path is the point: the
// alternative is the reader re-deriving the ladder from this file, which is how a
// rung stayed dead long enough to silence four tests.
func searched(looked []string) []string {
	if len(looked) == 0 {
		return []string{"(nowhere — the working directory could not be read)"}
	}
	return looked
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// Output is one child's two streams: rows on stdout, diagnostics on stderr, so a
// caller reads results from one and provenance from the other without either
// contaminating the other.
type Output struct {
	Stdout, Stderr string
	Code           int
}

// Spawn runs one verb of one face. ctx cancellation kills the child, so a Go caller's
// cancellation reaches this tier exactly as it reaches the in-process one. Exit
// code 2 is a fault about the query and is raised; 0 and 1 are both answers
// (ExitNoMatch means the verb ran and emitted no row).
func Spawn(ctx context.Context, tool string, argv []string, dir string) (Output, error) {
	bin, err := Binary(tool)
	if err != nil {
		return Output{}, err
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, coldTimeout)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, bin, argv...)
	cmd.Dir = dir
	cmd.Env = uncapped()
	cmd.Stdin = nil // a readable stdin would make the engine read it instead of walking
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	runErr := cmd.Run()
	res := Output{Stdout: out.String(), Stderr: errb.String(), Code: cmd.ProcessState.ExitCode()}
	if ctxErr := ctx.Err(); ctxErr != nil {
		return res, ctxErr
	}
	var exitErr *exec.ExitError
	switch {
	case runErr == nil, errors.As(runErr, &exitErr) && res.Code == analytic.ExitNoMatch:
		return res, nil
	case errors.As(runErr, &exitErr):
		detail := complaint(res.Stderr)
		if unsupported(res.Stderr) {
			return res, fmt.Errorf("%s %s: %s: %w", tool, argv[0], detail, ErrUnsupportedPattern)
		}
		if detail == "" {
			detail = died(cmd.ProcessState, res.Code)
		}
		return res, fmt.Errorf("%s %s: %s", tool, argv[0], detail)
	default:
		return res, fmt.Errorf("%s %s: %w", tool, argv[0], runErr)
	}
}

// died accounts for a child that said nothing on stderr. A signalled process has
// no exit code at all — ExitCode reports -1 — so reporting it as "exited -1" both
// invents a code and hides the one fact worth knowing: something outside the
// engine killed it, and there is no output because it never got to speak. On
// macOS a freshly linked binary's first exec is occasionally SIGKILLed by
// signature validation, which reads as an inexplicable engine fault until the
// signal is named.
func died(state *os.ProcessState, code int) string {
	if status, ok := state.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return fmt.Sprintf("killed by %v (no output; the engine did not fault)", status.Signal())
	}
	return fmt.Sprintf("exited %d", code)
}

// unsupportedMarkers are the phrases the engine prints when a pattern or flag is
// outside its linear-time syntax — the cold spelling of IRGX_STALE.
var unsupportedMarkers = [...]string{"unsupported", "use ripgrep", "use rg for this", "linear-time syntax", "not yet implemented"}

func unsupported(stderr string) bool {
	low := strings.ToLower(stderr)
	for _, m := range unsupportedMarkers {
		if strings.Contains(low, m) {
			return true
		}
	}
	return false
}

// uncapped lifts the CLI's agent output budget for this child: truncating a
// structured answer would silently break a program, and the engine keeps its own
// hard memory ceiling regardless.
func uncapped() []string {
	env := make([]string, 0, len(os.Environ())+1)
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "GIST_MAX_OUTPUT_BYTES=") || strings.HasPrefix(kv, "GIST_MAX_OUTPUT_TOKENS=") {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "GIST_UNCAP=1")
}

// complaint is the child's own account of the fault. The engine prints the
// incident on its first `error:` line and then coaching on the lines after it, so
// the last line is the advice, not the diagnosis.
func complaint(stderr string) string {
	lines := strings.Split(strings.TrimRight(stderr, "\n"), "\n")
	for _, line := range lines {
		if strings.Contains(line, "error:") {
			return strings.TrimSpace(line)
		}
	}
	return strings.TrimSpace(lines[len(lines)-1])
}

// cold answers q by running the certified binary and decoding its NDJSON. This
// is the fail-open tier: it needs no cgo, no shared library, and no analytic
// plane, so a CGO_ENABLED=0 host reaches all seventeen verbs through it.
func cold(ctx context.Context, q Query) (*Rows, error) {
	p, err := planVerb(q)
	if err != nil {
		return nil, err
	}
	start := time.Now()
	out, err := Spawn(ctx, p.tool, p.argv, q.Dir)
	waited := time.Since(start)
	if err != nil {
		return nil, err
	}
	rows, err := p.decode(out.Stdout)
	if err != nil {
		return nil, err
	}
	return newRows(&coldRows{rows: rows, facts: coldStats(out, len(rows), waited)}), nil
}

// coldRows serves an answer the child already materialized. A child's stdout is
// read whole because its exit code is part of the answer, so there is nothing to
// stream past that point.
type coldRows struct {
	rows  []Row
	facts Stats
}

func (c *coldRows) fill(dst []Row) (int, error) {
	n := copy(dst, c.rows)
	c.rows = c.rows[n:]
	return n, nil
}

func (c *coldRows) stats() Stats { return c.facts }
func (c *coldRows) close() error { return nil }

// coldStats reads the verb's own summary record — the machine-readable twin of
// the line the CLI prints for a human to glance at, and the only place the cold
// tier can learn what a row cannot carry (how large a population the answer was
// drawn from, how much of the query was foreign, what a budget trimmed).
// Best-effort by design: an absent record yields the row count alone rather than
// failing a query that already produced its rows.
//
// waited is the child's measured wall clock, and it is the floor under Elapsed
// rather than a fallback of last resort: the summary counts whole milliseconds,
// so a sub-millisecond verb reports `"ms":0` while the caller demonstrably waited
// for a process to start, answer, and exit. The in-process tier reports
// nanoseconds, and one tier may not answer "no time passed" where its twin
// answers a real duration. A summary that does report time still wins — it is the
// finer account of where the time went.
func coldStats(out Output, rows int, waited time.Duration) Stats {
	s := Stats{Rows: uint64(rows), Elapsed: waited}
	diag := summary(out.Stdout, out.Stderr)
	if diag == nil {
		return s
	}
	s.Source = sourceOrdinal(text(diag["source"]))
	s.FilesConsidered = counter(diag, "files", "units", "indexed_files", "read_files", "total_files", "shelf_files")
	s.Refreshed = counter(diag, "refreshed")
	s.Foreign = counter(diag, "foreign")
	s.Omitted = counter(diag, "omitted")
	if n := counter(diag, "rows", "picks", "hits", "located"); s.Rows == 0 {
		s.Rows = n
	}
	if reported := elapsed(diag); reported > 0 {
		s.Elapsed = reported
	}
	return s
}

// elapsed totals every millisecond counter the summary reports. A verb spells its
// phases separately (index_ms + query_ms, load_ms + compute_ms), and their sum is
// the wall clock the caller actually waited.
func elapsed(diag map[string]any) time.Duration {
	var ms float64
	for key, raw := range diag {
		if key != "ms" && !strings.HasSuffix(key, "_ms") {
			continue
		}
		if v, ok := number(raw); ok {
			ms += v
		}
	}
	return time.Duration(ms * float64(time.Millisecond))
}

func sourceOrdinal(name string) uint32 {
	switch name {
	case "atlas":
		return analytic.SourceAtlas
	case "shelf":
		return analytic.SourceShelf
	default:
		return analytic.SourceLive
	}
}

func counter(diag map[string]any, keys ...string) uint64 {
	for _, k := range keys {
		if n, ok := number(diag[k]); ok && n >= 0 {
			return uint64(n)
		}
	}
	return 0
}
