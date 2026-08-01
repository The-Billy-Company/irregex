package runtime

import (
	"fmt"
	"strconv"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
)

// plan is one verb lowered onto a child process: which face of the kernel to
// run, its argv, and how to read the answer back as rows of the verb's declared
// schema. Every verb's CLI spelling lives here and nowhere else, so the CLI's own
// consolidation (a channel and a shape are flags, not verbs) is absorbed in one
// table rather than scattered across the verb packages.
type plan struct {
	tool   string
	argv   []string
	decode func(stdout string) ([]Row, error)
}

func planVerb(q Query) (plan, error) {
	verb, ok := analytic.Verb(q.Op)
	if !ok {
		return plan{}, fmt.Errorf("irregex: unknown analytic op %d", q.Op)
	}
	argv, tool, err := coldArgv(q)
	if err != nil {
		return plan{}, err
	}
	schema := verb.Schema
	decode := func(out string) ([]Row, error) { return rowsPerObject(schema, out) }
	switch q.Op {
	case analytic.OpQuote:
		decode = func(out string) ([]Row, error) { return headThenRows(schema, out) }
	case analytic.OpRank:
		decode = func(out string) ([]Row, error) { return rankedRows(schema, out) }
	default: // one object per row is the NDJSON convention every other verb keeps
	}
	return plan{tool: tool, argv: argv, decode: decode}, nil
}

// coldArgv lowers a query onto the CLI. The kinship verbs collapsed into two
// (`similar` for the neighbor question, `echoes` for the repetition question)
// with unit × channel × shape as flags, so seven contract ops share one binary
// verb and differ only in the axes set here.
func coldArgv(q Query) (argv []string, tool string, err error) {
	switch p := q.Params.(type) {
	case analytic.Kinship:
		argv, err = kinshipArgv(q.Op, p)
		return append(argv, q.Roots...), ToolRelate, err
	case analytic.Retrieval:
		argv, err = retrievalArgv(q.Op, p)
		if q.Op == analytic.OpQuote {
			return argv, ToolRelate, err // quote prices against the whole corpus shelf
		}
		return append(argv, q.Roots...), ToolRelate, err
	case analytic.Sweep:
		return append(sweepArgv(q.Op, p), q.Roots...), ToolRelate, nil
	case analytic.Compose:
		argv, tool, err = composeArgv(q.Op, p)
		return append(argv, q.Roots...), tool, err
	case analytic.Rank:
		req := analytic.Request{Pattern: p.Pattern, Fixed: p.Fixed, IgnoreCase: p.IgnoreCase}
		// The ranked view is a rendered answer, so drop Argv's leading --json
		// rather than asking for a record stream the engine would print instead.
		argv = append([]string{rankFlag(p.Top)}, req.Argv(q.Roots...)[1:]...)
		return argv, ToolGist, nil
	}
	return nil, "", fmt.Errorf("irregex: %s params (%T) have no subprocess lowering", q.Op, q.Params)
}

func kinshipArgv(op analytic.Op, k analytic.Kinship) ([]string, error) {
	if op == analytic.OpSimilar {
		if k.Target == "" {
			return nil, fmt.Errorf("irregex: similar needs a probe (a path, path#Lnnn, or text)")
		}
		argv := []string{"similar", k.Target, "--as", k.Channel.String(), "--unit", k.Unit.String()}
		return append(argv, kinshipTail(k)...), nil
	}
	// The repetition verb, with the retired verb names as flag combinations.
	shape, channel, unit := "pairs", k.Channel, k.Unit
	switch op {
	case analytic.OpDups:
		channel = analytic.ChannelCopies
	case analytic.OpClusters:
		shape, channel = "families", analytic.ChannelCopies
	case analytic.OpEchoes:
		channel = analytic.ChannelTwins
	case analytic.OpConcepts:
		shape, channel, unit = "families", analytic.ChannelShapes, analytic.UnitFunction
	case analytic.OpFragments:
		shape, unit = "families", analytic.UnitFunction
	case analytic.OpDistinct:
		shape = "distinct"
	default:
		return nil, fmt.Errorf("irregex: %s is not a kinship verb", op)
	}
	argv := []string{"echoes", "--shape", shape, "--as", channel.String(), "--unit", unit.String()}
	return append(argv, kinshipTail(k)...), nil
}

// kinshipTail carries only what the caller actually set: an unset threshold must
// stay unset so the engine's documented default applies, which is the same reason
// the C struct spends presence bits on exactly these two.
func kinshipTail(k analytic.Kinship) []string {
	tail := []string{"--json"}
	if k.MaxDistance != nil {
		tail = append(tail, "--max-distance", ftoa(*k.MaxDistance))
	}
	if k.MinEcho != nil {
		tail = append(tail, "--min-echo", ftoa(*k.MinEcho))
	}
	if k.MinGrade > analytic.GradeNone {
		tail = append(tail, "--min-grade", k.MinGrade.String())
	}
	for _, opt := range []struct {
		flag string
		n    int
	}{{"--min-size", k.MinSize}, {"--min-lines", k.MinLines}, {"--top", k.Top}} {
		if opt.n > 0 {
			tail = append(tail, opt.flag, strconv.Itoa(opt.n))
		}
	}
	if k.NoIndex {
		tail = append(tail, "--no-index")
	}
	return tail
}

func retrievalArgv(op analytic.Op, r analytic.Retrieval) ([]string, error) {
	var verb string
	switch op {
	case analytic.OpRecall:
		verb = "similar" // bare text scores the recall channel
	case analytic.OpPack:
		verb = "pack"
	case analytic.OpQuote:
		verb = "quote"
	default:
		return nil, fmt.Errorf("irregex: %s is not a retrieval verb", op)
	}
	if r.Query == "" {
		return nil, fmt.Errorf("irregex: %s needs query text", op)
	}
	argv := []string{verb, r.Query, "--json"}
	if r.Top > 0 && op != analytic.OpQuote {
		argv = append(argv, "--top", strconv.Itoa(r.Top))
	}
	if r.NoIndex && op != analytic.OpQuote {
		argv = append(argv, "--no-index")
	}
	return argv, nil
}

func sweepArgv(op analytic.Op, s analytic.Sweep) []string {
	argv := []string{"patterns", "--json"}
	for _, pat := range s.Patterns {
		argv = append(argv, "-e", pat)
	}
	argv = append(argv, matchFlags(s.Fixed, s.IgnoreCase)...)
	if s.Under != "" {
		argv = append(argv, "--under", s.Under)
	}
	if s.Top > 0 {
		argv = append(argv, "--top", strconv.Itoa(s.Top))
	}
	if op == analytic.OpPatternCounts {
		by := "pattern"
		if s.ByFile {
			by = "file"
		}
		argv = append(argv, "--by", by)
	}
	return argv
}

// composeArgv lowers the both-engines verbs. context and family are the exact
// engine narrowing a candidate set for a retrieval or repetition question, which
// the CLI now spells as `--matching` on those verbs rather than as separate ones;
// provenance and blast remain their own face because their answers are shapes
// neither kinship nor retrieval has.
func composeArgv(op analytic.Op, c analytic.Compose) ([]string, string, error) {
	narrow := func() []string {
		argv := []string{}
		for _, pat := range c.Patterns {
			argv = append(argv, "--matching", pat)
		}
		if c.MatchAll {
			argv = append(argv, "--match", "all")
		}
		return append(argv, matchFlags(c.Fixed, c.IgnoreCase)...)
	}
	switch op {
	case analytic.OpContext:
		if c.Text == "" {
			return nil, "", fmt.Errorf("irregex: context needs task text")
		}
		argv := append([]string{"pack", c.Text, "--json"}, narrow()...)
		if c.Top > 0 {
			argv = append(argv, "--top", strconv.Itoa(c.Top))
		}
		return argv, ToolRelate, nil
	case analytic.OpFamily:
		argv := append([]string{"echoes", "--shape", "families", "--json"}, narrow()...)
		if c.Unit != analytic.UnitFile {
			argv = append(argv, "--unit", c.Unit.String())
		}
		// The threshold picks the channel, because the composed family verb
		// defaults to the echo gap: a byte threshold on the gap channel would be
		// read against a quantity of the opposite polarity and find nothing.
		if c.MaxDistance != nil {
			argv = append(argv, "--as", analytic.ChannelCopies.String(), "--max-distance", ftoa(*c.MaxDistance))
		}
		if c.MinEcho != nil {
			argv = append(argv, "--as", analytic.ChannelTwins.String(), "--min-echo", ftoa(*c.MinEcho))
		}
		if c.Top > 0 {
			argv = append(argv, "--top", strconv.Itoa(c.Top))
		}
		return argv, ToolRelate, nil
	case analytic.OpProvenance:
		if c.Text == "" {
			return nil, "", fmt.Errorf("irregex: provenance needs the pasted text")
		}
		return []string{"provenance", c.Text, "--json"}, ToolBlast, nil
	case analytic.OpBlast:
		if c.Text == "" {
			return nil, "", fmt.Errorf("irregex: blast needs a symbol")
		}
		argv := []string{"blast", c.Text, "--json"}
		if c.Budget > 0 {
			argv = append(argv, "--budget", strconv.Itoa(c.Budget))
		}
		return argv, ToolBlast, nil
	default:
		return nil, "", fmt.Errorf("irregex: %s is not a composed verb", op)
	}
}

func matchFlags(fixed, ignoreCase bool) []string {
	var argv []string
	if fixed {
		argv = append(argv, "-F")
	}
	if ignoreCase {
		argv = append(argv, "-i")
	}
	return argv
}

func rankFlag(top int) string {
	if top <= 0 {
		return "--rank"
	}
	return "--rank=" + strconv.Itoa(top)
}

func ftoa(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }
