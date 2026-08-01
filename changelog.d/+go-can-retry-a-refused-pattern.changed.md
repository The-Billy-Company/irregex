A Go caller can now retry a refused pattern instead of giving up on it.

Every `Compile` failure used to be one `*irregex.Error` reading `invalid: bad
argument, or a pattern this arm cannot compile (Unsupported)`. So if a pattern
came from a config file or a flag or a user, there was nothing to branch on -
`foo(?=bar)` is one flag away from working and `[abc` is just broken, and the
binding could not tell you which one you had, or where.

Now the two refusals are two Go types, and both fall out of the status code:

```go
re, err := irregex.Compile(pattern)
if errors.Is(err, irregex.ErrNeedsPCRE) {
	re, err = irregex.CompileOpts{PCRE: true}.Compile(pattern)
}
```

`ErrNeedsPCRE` is the linear grammar declining a construct the vendored PCRE2
has - lookaround, a backreference, an atomic group. It is not a defect, so it
carries no offset and no fault: the seam declines by returning `IRREGEX_STALE`
and installs nothing, and this binding reads nothing, which also means a
declinature can never pick up the detail an earlier failure left on the same
thread. Malformed text is a `*SyntaxError` instead, with `Expr`, the byte offset
in `At`, and the engine's word for the defect, so you can print a caret under
the byte it stopped on. `At` is `-1` when there is no position rather than a
stand-in `0`, since byte 0 is a real answer. It unwraps to the `*irregex.Error`
it always was, so nothing that used to work stopped.

Both classes come from the return value alone. There is no fault-name string
compared anywhere in the binding, which is the point - a construct list is the
thing that drifts.

The vendored archives are rebuilt on the fixed engine, and the retry idiom is
covered end to end: four declined constructs that must compile once the flag is
set, five malformed ones that must not, at the offsets the engine reports.
