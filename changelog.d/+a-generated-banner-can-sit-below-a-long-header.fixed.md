`isGenerated` read the first eight lines for a `Code generated ... DO NOT EDIT` banner. That works for the generators that stamp line one, and fails for every generator that carries its source contract's leading comment above its own banner - `protoc-gen-connect-go` puts a 24-line proto comment first, so the marker lands at line 26 and the file reads as hand-written.

Now the header is the leading run of comment and blank lines, however long that is, and the old eight-line count survives as a floor for banners that sit just under a package clause. The scan still stops at the first line of real code, so a mention in the body is a mention, not a banner, and it is still capped at 2048 bytes.

`isGeneratedPath` also learned `.connect.go` and `.connect.swift`, the two buf output names with no generator token in them. Callers holding no file bytes - the atlas-warm kinship verbs - get the demotion from the name alone.
