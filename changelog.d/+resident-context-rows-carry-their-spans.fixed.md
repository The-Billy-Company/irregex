The resident record stream now reports context rows the way ripgrep does. Two
things were wrong, and both only showed up once a caller asked for context
through the in-process face rather than the CLI.

Submatch spans were collected only for rows classified as matches, and only
when the search was not inverted. But rg paints spans on whatever line it
prints, and under `-v` a context row is *by definition* a line the pattern
matched — so `rg -v -C1` reports that line's spans and we reported none. The
cold path already had this right and said so in a comment; the resident twin
had drifted. Spans are now collected from the line's own content, which
answers correctly for every combination without a special case.

Separately, `-m` was treated as a hard stop. rg stops *selecting* at the cap
but keeps searching that match's after-context window, and a line inside the
window that matches prints as a match rather than as context; the window does
not chain. `gist -m1 -A1` through the resident face called that line context
and dropped its spans. The cap is now a position to measure from, mirroring
the cold engine's `cap_at`.

Found by the FFI-vs-cold parity suite, which compares every face against the
cold engine that is itself held byte-identical to ripgrep.
