Towncrier ran with `wrap = true`, which is right for one-line release notes and
wrong for the multi-paragraph Markdown the fragments here actually are. It
reflows each entry as one flat block, so a fenced code sample lost its fence, a
hanging `-` at the end of a wrapped line became a setext heading, an inline code
span got split across a paragraph break, and the `*` that fell to the start of
the next line was read as a bullet. The v1.0.0 fold surfaced 25 markdownlint
findings that were all the same bug wearing different rule numbers.

Off, the fragment's own layout survives and towncrier only indents it. Three
fragments that were relying on the reflow - a broken `len >= 16 * k * budget`
span, an indented `pshufb` sample, and four `*` bullets in a document whose
other lists are dashes - are corrected at the source, so the fold is clean
rather than patched afterwards.
