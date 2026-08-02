//go:build cgo

package irgx

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// Split slices s around the matches, returning the pieces between them.
//
// n bounds the number of pieces: negative for all of them, zero for none, and
// n > 0 for at most n, where the last piece is the unsplit remainder.
//
// The separators are the engine's match sequence, so a nullable pattern splits
// differently here than in [regexp]: an empty match is suppressed at the end of
// s and where the previous match ended, and no piece is produced for it.
func (re *Regexp) Split(s string, n int) []string {
	if n == 0 {
		return nil
	}
	// Splitting an empty text yields one empty piece, the way strings.Split
	// does. The loop below cannot produce it: there is no separator to hang it
	// on, since nothing matches inside nothing.
	if len(s) == 0 {
		return []string{""}
	}
	matches := re.all(s, n)
	out := make([]string, 0, len(matches)+1)
	begin, end := 0, 0
	for _, span := range matches {
		if n > 0 && len(out) >= n-1 {
			break
		}
		end = span[0]
		// A match that ends at offset 0 is an empty match before the first byte.
		// It separates nothing, so it earns no leading empty piece.
		if span[1] != 0 {
			out = append(out, s[begin:end])
		}
		begin = span[1]
	}
	if end != len(s) {
		out = append(out, s[begin:])
	}
	return out
}

// ReplaceAllString returns src with every match replaced by repl, in which $1,
// ${1} and ${name} expand to the corresponding group. See [Regexp.Expand] for
// the template grammar.
func (re *Regexp) ReplaceAllString(src, repl string) string {
	out := re.rebuild(src, strings.Contains(repl, "$"), func(dst []byte, match []int) []byte {
		return re.expand(dst, repl, src, match)
	})
	if out == nil {
		return src
	}
	return string(out)
}

// ReplaceAllLiteralString returns src with every match replaced by repl
// verbatim, with no $ expansion.
func (re *Regexp) ReplaceAllLiteralString(src, repl string) string {
	out := re.rebuild(src, false, func(dst []byte, _ []int) []byte {
		return append(dst, repl...)
	})
	if out == nil {
		return src
	}
	return string(out)
}

// ReplaceAllStringFunc returns src with every match replaced by the result of
// repl applied to the matched text. The result is substituted directly; $ in it
// is not expanded.
func (re *Regexp) ReplaceAllStringFunc(src string, repl func(string) string) string {
	out := re.rebuild(src, false, func(dst []byte, match []int) []byte {
		return append(dst, repl(src[match[0]:match[1]])...)
	})
	if out == nil {
		return src
	}
	return string(out)
}

// ReplaceAll returns a copy of src with every match replaced by repl, in which
// $1, ${1} and ${name} expand to the corresponding group.
func (re *Regexp) ReplaceAll(src, repl []byte) []byte {
	text := borrow(src)
	template := borrow(repl)
	return orCopy(re.rebuild(text, strings.Contains(template, "$"), func(dst []byte, match []int) []byte {
		return re.expand(dst, template, text, match)
	}), src)
}

// ReplaceAllLiteral returns a copy of src with every match replaced by repl
// verbatim, with no $ expansion.
func (re *Regexp) ReplaceAllLiteral(src, repl []byte) []byte {
	return orCopy(re.rebuild(borrow(src), false, func(dst []byte, _ []int) []byte {
		return append(dst, repl...)
	}), src)
}

// ReplaceAllFunc returns a copy of src with every match replaced by the result
// of repl applied to the matched text. The result is substituted directly; $ in
// it is not expanded.
func (re *Regexp) ReplaceAllFunc(src []byte, repl func([]byte) []byte) []byte {
	return orCopy(re.rebuild(borrow(src), false, func(dst []byte, match []int) []byte {
		return append(dst, repl(src[match[0]:match[1]])...)
	}), src)
}

// rebuild walks the match sequence once and reassembles src around it, calling
// emit in place of each match. It returns nil when nothing matched, which is
// how the callers avoid copying a string they were not going to change.
//
// groups says whether emit reads past match[0:2]; capture detail is a second
// engine call per match, so it is only paid for when a template asks for it.
func (re *Regexp) rebuild(src string, groups bool, emit func(dst []byte, match []int) []byte) []byte {
	h := re.acquire()
	defer re.release(h)
	spans := re.findSpans(h, src, -1)
	if len(spans) == 0 {
		return nil
	}
	out := make([]byte, 0, len(src))
	last := 0
	for _, span := range spans {
		out = append(out, src[last:span[0]]...)
		match := span[:]
		if groups {
			match = re.findGroups(h, src, span[0], span[1])
		}
		out = emit(out, match)
		last = span[1]
	}
	return append(out, src[last:]...)
}

func orCopy(out []byte, src []byte) []byte {
	if out == nil {
		return append([]byte(nil), src...)
	}
	return out
}

// ExpandString appends template to dst with its $-references replaced by the
// groups of match, which must come from src via [Regexp.FindStringSubmatchIndex]
// or one of its All siblings.
//
// A reference is $name or ${name}, where name runs over letters, digits and
// underscore. A name that is all digits is a group number, otherwise it is a
// group name. $$ is a literal dollar. A reference to a group that does not
// exist, or one this match did not enter, expands to nothing - the same rule
// [regexp] follows, and the reason ${1} exists: $1x asks for the group named
// "1x".
func (re *Regexp) ExpandString(dst []byte, template string, src string, match []int) []byte {
	return re.expand(dst, template, src, match)
}

// Expand appends template to dst with its $-references replaced by the groups
// of match, which must come from src via [Regexp.FindSubmatchIndex] or one of
// its All siblings. See [Regexp.ExpandString] for the grammar.
func (re *Regexp) Expand(dst []byte, template []byte, src []byte, match []int) []byte {
	return re.expand(dst, borrow(template), borrow(src), match)
}

func (re *Regexp) expand(dst []byte, template, src string, match []int) []byte {
	for {
		dollar := strings.IndexByte(template, '$')
		if dollar < 0 {
			return append(dst, template...)
		}
		dst, template = append(dst, template[:dollar]...), template[dollar+1:]
		name, rest, ok := reference(template)
		template = rest
		if !ok {
			// A dollar that begins nothing is a dollar. This is also the $$
			// case, since reference consumes a leading '$' and declines it.
			dst = append(dst, '$')
			continue
		}
		if n := re.groupNumber(name); n >= 0 && 2*n+1 < len(match) && match[2*n] >= 0 {
			dst = append(dst, src[match[2*n]:match[2*n+1]]...)
		}
	}
}

// reference reads one $-reference off the front of s, having already consumed
// the dollar. It reports failure for anything that is not a name, and rest is
// then what still has to be copied through - the whole of s, except for the $$
// case, where the second dollar has been eaten.
func reference(s string) (name, rest string, ok bool) {
	if s == "" {
		return "", "", false
	}
	if s[0] == '$' {
		return "", s[1:], false
	}
	body := s
	braced := body[0] == '{'
	if braced {
		body = body[1:]
	}
	end := 0
	for end < len(body) {
		r, size := utf8.DecodeRuneInString(body[end:])
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '_' {
			break
		}
		end += size
	}
	if end == 0 {
		return "", s, false
	}
	name = body[:end]
	if braced {
		if end >= len(body) || body[end] != '}' {
			return "", s, false
		}
		end++
	}
	return name, body[end:], true
}

// groupNumber resolves a template reference to a group number, or -1. An
// all-digit name is a number; anything else is looked up in the engine-confirmed
// name table.
func (re *Regexp) groupNumber(name string) int {
	digits := name[0] != '0' || len(name) == 1
	number := 0
	for i := 0; digits && i < len(name); i++ {
		if name[i] < '0' || name[i] > '9' {
			digits = false
		} else {
			number = number*10 + int(name[i]-'0')
		}
	}
	if digits {
		return number
	}
	return re.SubexpIndex(name)
}
