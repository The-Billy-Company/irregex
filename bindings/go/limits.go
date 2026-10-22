//go:build cgo

package irgx

// CompileLimits are PCRE2 execution ceilings. Zero is a real limit; use
// UnspecifiedLimit to retain the engine's default for an individual ceiling.
// They are inert for the linear engine. Depth and heap ceilings select the
// PCRE2 interpreter because its JIT does not enforce them.
type CompileLimits struct {
	MatchSteps uint64
	Depth      uint64
	HeapBytes  uint64
}

// UnspecifiedLimit leaves a CompileLimits ceiling at the engine's default.
const UnspecifiedLimit uint64 = ^uint64(0)

// CompileLimited compiles expr under explicit execution ceilings.
func CompileLimited(expr string, limits CompileLimits) (*Regexp, error) {
	return CompileOpts{}.CompileLimited(expr, limits)
}

// CompileLimited retains limits for every pooled worker, including lazy capture
// queries. Compilation also checks the empty subject to resolve Go's nullable
// matching convention; a ceiling preventing that check is returned as an error.
// MatchString and Match panic on execution-budget exhaustion; TryMatchString
// returns the error. The existing Find methods retain the native span behavior,
// which can stop with an empty or partial result on PCRE exhaustion.
func (o CompileOpts) CompileLimited(expr string, limits CompileLimits) (*Regexp, error) {
	return o.compile(expr, &limits)
}

// TryMatchString reports whether text contains a match, returning native errors
// such as an exhausted CompileLimits allowance instead of panicking.
func (re *Regexp) TryMatchString(text string) (bool, error) {
	h, err := re.acquireError()
	if err != nil {
		return false, err
	}
	defer re.release(h)
	return re.matchOnError(h, text)
}
