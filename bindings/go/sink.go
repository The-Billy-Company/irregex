//go:build cgo

package irgx

// The cap/written protocol, written once.
//
// Fourteen verbs across five planes hand back a variable-length answer the same
// way: you pass a buffer and a cap, at most cap elements are written, and
// *written reports how many EXIST. That last clause is the whole design, and it
// is why this can be one helper rather than a grow-and-rescan loop per verb - a
// short buffer measures its own retry, so there is at most ONE retry and no
// doubling loop. The header says so at irgx_find_all and every sibling verb
// inherits it: `written` is never saturated at `cap`, because "did I get
// everything?" has to stay decidable.
//
// The two batch pullers are deliberately NOT here. irgx_matches_next_batch and
// irgx_walk_next_batch report what the call CONSUMED rather than what exists,
// which is a different protocol wearing similar parameters, and routing them
// through this would turn "I took four of the remaining thousand" into a retry
// for a thousand.

// drain runs a cap/written verb and returns exactly the elements that exist.
//
// want is the first buffer to try: a caller that knows the exact ceiling (a
// slate's length, a pattern's group count) passes it and the second pass never
// happens; a caller that does not passes a guess, or 0 to ask the count-only
// question first and allocate once, exactly.
//
// run reports (how many exist, status). A negative status yields a nil answer,
// because a failed call has no elements rather than zero of them - the caller
// reads the status to tell those apart.
func drain[T any](want int, run func(buf []T) (have int, st int32)) ([]T, int32) {
	buf := make([]T, max(want, 0))
	have, st := run(buf)
	if st < 0 {
		return nil, st
	}
	if have > len(buf) {
		// The count the engine just measured, so this cannot come up short
		// again. It can come up LONG if the answer shrank under a concurrent
		// mutation of the corpus, which is why the second count is believed
		// over the first rather than the buffer being trusted to its end.
		buf = make([]T, have)
		again, st2 := run(buf)
		if st2 < 0 {
			return nil, st2
		}
		have = min(again, len(buf))
	}
	if have == 0 {
		return nil, st
	}
	return buf[:have], st
}

// head is the address C writes through, or NULL for an empty buffer.
//
// &buf[0] is not addressable at length zero, and zero length is not a corner
// case here: it is how the ABI spells a count-only query (cap 0 with a NULL
// out), which several of these verbs answer more cheaply than a real one.
func head[T any](buf []T) *T {
	if len(buf) == 0 {
		return nil
	}
	return &buf[0]
}
