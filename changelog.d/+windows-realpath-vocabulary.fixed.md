`portal.realpath` returned native `\` separators on Windows, into a codebase
whose entire path vocabulary is `/`. The walker already normalized its own output
before an ignore rule or a depth count saw it, but the resolver did not, so
anything downstream that split on `/` read a resolved path as a single component:
`delta.keyFor` could not derive a dirty-log key, which made a scoped reconcile
key on the whole path and symlink identity compare unequal to the same file
reached another way. It now normalizes non-UNC results the way the walker does,
so one path spelling means one thing on both platforms. `--path-separator` still
renders native `\` on request; that is a presentation choice at the edge, which
is where it belonged all along.
