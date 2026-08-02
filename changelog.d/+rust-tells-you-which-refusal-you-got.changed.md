A Rust caller can now retry a refused pattern on the other engine in two lines,
and point at the byte a malformed one died on.

`Regex::new(r"(?<=\$)\d+")` used to come back as one opaque `Error::Pattern`
carrying a fault name and no position - the same answer `[abc` gave. So the two
things you can do about a refusal, retry it with `pcre(true)` or show the user
where they went wrong, were both unavailable, because you could not tell which
refusal you had.

Now the C seam answers `IRGX_STALE` for the first and `IRGX_INVALID` with
an offset for the second, and the enum says so:

```rust
match Regex::new(pattern) {
    Err(Error::NeedsPcre { .. }) => RegexBuilder::new(pattern).pcre(true).build(),
    other => other,
}
```

`Error::Syntax` carries `at`, a byte index into the pattern you handed over,
and it is a real index - never past the end, never mid-codepoint - so
`&pattern[..at]` is the part the engine got through and a caret under it needs
no bounds check. An offset that would not slice is dropped to `Error::Pattern`
rather than reported wrong. `Error::Pattern` is still there, and is now what it
should always have been: the engine's own ceilings, where no single byte is the
problem so there is no offset to invent.

Which variant you get is decided by the status code alone. Nothing in the crate
compares a fault name as a string any more, so a build that renames a fault
cannot silently turn a retryable pattern into a syntax error. And because a
declinature installs no fault, `NeedsPcre` reads nothing from the fault slot -
it cannot pick up the leftovers of somebody else's failure.

The retry is not done for you on purpose. The linear engine is linear in the
length of the text and the PCRE2 arm is not, so a program compiling patterns
a stranger typed may want to report and stop. Both are one match arm.

Two new variants on a `#[non_exhaustive]` enum, appended, so `cargo-semver-checks`
calls it minor.
