//go:build cgo

package irgx

// The Find family, in stdlib [regexp] shape. Two conventions carry through all
// of it.
//
// An index result is a byte offset into the caller's own string or slice, so
// s[loc[0]:loc[1]] is the matched text. Go strings are UTF-8 and indexed by
// byte, which is what the engine reports, so there is no translation step here
// and none is wanted.
//
// A group the match did not enter is -1, -1 in an Index result and nil in a
// [][]byte result. In a []string result it is the empty string, which is
// [regexp]'s convention and is genuinely ambiguous with a group that matched
// empty; reach for the Index form when the difference matters.

// MatchString reports whether s contains a match. It rides the engine's
// cheapest verb, which may stop at the first hit and never materialize a span.
func (re *Regexp) MatchString(s string) bool { return re.isMatch(s) }

// Match reports whether b contains a match.
func (re *Regexp) Match(b []byte) bool { return re.isMatch(borrow(b)) }

// ── one match ────────────────────────────────────────────────────────────────

// FindStringIndex returns a two-element slice holding the byte offsets of the
// leftmost match, or nil if there is none.
func (re *Regexp) FindStringIndex(s string) []int { return pair(re.first(s)) }

// FindIndex returns a two-element slice holding the byte offsets of the
// leftmost match, or nil if there is none.
func (re *Regexp) FindIndex(b []byte) []int { return pair(re.first(borrow(b))) }

// FindString returns the text of the leftmost match, or "" if there is none.
// "" is also what an empty match returns; [Regexp.FindStringIndex] tells them
// apart.
func (re *Regexp) FindString(s string) string {
	span, ok := re.first(s)
	if !ok {
		return ""
	}
	return s[span[0]:span[1]]
}

// Find returns the text of the leftmost match, or nil if there is none. The
// result aliases b.
func (re *Regexp) Find(b []byte) []byte {
	span, ok := re.first(borrow(b))
	if !ok {
		return nil
	}
	return b[span[0]:span[1]:span[1]]
}

// FindStringSubmatchIndex returns the byte offsets of the leftmost match and
// its groups, or nil if there is none. Element pair 0 is the whole match, pair
// k is group k, and a group the match did not enter is -1, -1.
func (re *Regexp) FindStringSubmatchIndex(s string) []int { return re.firstGroups(s) }

// FindSubmatchIndex returns the byte offsets of the leftmost match and its
// groups, or nil if there is none.
func (re *Regexp) FindSubmatchIndex(b []byte) []int { return re.firstGroups(borrow(b)) }

// FindStringSubmatch returns the text of the leftmost match and its groups, or
// nil if there is none.
func (re *Regexp) FindStringSubmatch(s string) []string {
	return sliceStrings(s, re.firstGroups(s))
}

// FindSubmatch returns the text of the leftmost match and its groups, or nil if
// there is none. A group the match did not enter is nil, distinct from an empty
// group. The results alias b.
func (re *Regexp) FindSubmatch(b []byte) [][]byte {
	return sliceBytes(b, re.firstGroups(borrow(b)))
}

// ── every match ──────────────────────────────────────────────────────────────
//
// n bounds the number of matches: negative for all of them, and zero for none,
// which is [regexp]'s convention. All of these return nil when nothing matched.

// FindAllStringIndex returns the byte offsets of successive matches.
func (re *Regexp) FindAllStringIndex(s string, n int) [][]int {
	return pairs(re.all(s, n))
}

// FindAllIndex returns the byte offsets of successive matches.
func (re *Regexp) FindAllIndex(b []byte, n int) [][]int {
	return pairs(re.all(borrow(b), n))
}

// FindAllString returns the text of successive matches.
func (re *Regexp) FindAllString(s string, n int) []string {
	spans := re.all(s, n)
	if len(spans) == 0 {
		return nil
	}
	out := make([]string, len(spans))
	for i, span := range spans {
		out[i] = s[span[0]:span[1]]
	}
	return out
}

// FindAll returns the text of successive matches. The results alias b.
func (re *Regexp) FindAll(b []byte, n int) [][]byte {
	spans := re.all(borrow(b), n)
	if len(spans) == 0 {
		return nil
	}
	out := make([][]byte, len(spans))
	for i, span := range spans {
		out[i] = b[span[0]:span[1]:span[1]]
	}
	return out
}

// FindAllStringSubmatchIndex returns the byte offsets of successive matches and
// their groups.
func (re *Regexp) FindAllStringSubmatchIndex(s string, n int) [][]int {
	return re.allGroups(s, n)
}

// FindAllSubmatchIndex returns the byte offsets of successive matches and their
// groups.
func (re *Regexp) FindAllSubmatchIndex(b []byte, n int) [][]int {
	return re.allGroups(borrow(b), n)
}

// FindAllStringSubmatch returns the text of successive matches and their groups.
func (re *Regexp) FindAllStringSubmatch(s string, n int) [][]string {
	found := re.allGroups(s, n)
	if len(found) == 0 {
		return nil
	}
	out := make([][]string, len(found))
	for i, match := range found {
		out[i] = sliceStrings(s, match)
	}
	return out
}

// FindAllSubmatch returns the text of successive matches and their groups. The
// results alias b.
func (re *Regexp) FindAllSubmatch(b []byte, n int) [][][]byte {
	found := re.allGroups(borrow(b), n)
	if len(found) == 0 {
		return nil
	}
	out := make([][][]byte, len(found))
	for i, match := range found {
		out[i] = sliceBytes(b, match)
	}
	return out
}

// ── the shared middle ────────────────────────────────────────────────────────

func (re *Regexp) first(text string) ([2]int, bool) {
	h := re.acquire()
	defer re.release(h)
	spans := re.findSpans(h, text, 1)
	if len(spans) == 0 {
		return [2]int{}, false
	}
	return spans[0], true
}

func (re *Regexp) firstGroups(text string) []int {
	h := re.acquire()
	defer re.release(h)
	spans := re.findSpans(h, text, 1)
	if len(spans) == 0 {
		return nil
	}
	return re.findGroups(h, text, spans[0][0], spans[0][1])
}

func (re *Regexp) all(text string, n int) [][2]int {
	h := re.acquire()
	defer re.release(h)
	return re.findSpans(h, text, n)
}

// allGroups holds one handle across the whole walk: the spans come from a single
// find_all, and the per-match captures only fill in detail for spans the engine
// has already blessed.
func (re *Regexp) allGroups(text string, n int) [][]int {
	h := re.acquire()
	defer re.release(h)
	spans := re.findSpans(h, text, n)
	if len(spans) == 0 {
		return nil
	}
	out := make([][]int, len(spans))
	for i, span := range spans {
		out[i] = re.findGroups(h, text, span[0], span[1])
	}
	return out
}

func pair(span [2]int, ok bool) []int {
	if !ok {
		return nil
	}
	return []int{span[0], span[1]}
}

func pairs(spans [][2]int) [][]int {
	if len(spans) == 0 {
		return nil
	}
	out := make([][]int, len(spans))
	for i, span := range spans {
		out[i] = []int{span[0], span[1]}
	}
	return out
}

func sliceStrings(s string, match []int) []string {
	if match == nil {
		return nil
	}
	out := make([]string, len(match)/2)
	for i := range out {
		if match[2*i] >= 0 {
			out[i] = s[match[2*i]:match[2*i+1]]
		}
	}
	return out
}

func sliceBytes(b []byte, match []int) [][]byte {
	if match == nil {
		return nil
	}
	out := make([][]byte, len(match)/2)
	for i := range out {
		if match[2*i] >= 0 {
			out[i] = b[match[2*i]:match[2*i+1]:match[2*i+1]]
		}
	}
	return out
}
