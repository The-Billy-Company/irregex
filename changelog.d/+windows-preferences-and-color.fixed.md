Two things a Windows user could not reach: their preferences file, and color.

**Preferences.** `locate()` looked in `$XDG_CONFIG_HOME`, then `$HOME` — neither of
which a Windows shell sets — so the machine-local preferences file was
unreachable on the platform and `gist config` had nothing to report. It now falls
through to `%LOCALAPPDATA%`, then `%USERPROFILE%\.config` for a ported dotfile
setup. `LOCALAPPDATA` rather than `APPDATA` is the whole point of the feature:
`APPDATA` roams between machines, and a preferences file that follows you onto
another machine is precisely the `.ripgreprc` hazard this design exists to avoid.
`XDG_CONFIG_HOME` is still consulted first everywhere, because a Windows user who
sets it means it.

**Color.** `--color=auto` resolved to *off* on every Windows console, because an
absent `TERM` was read as "not a terminal" — and no Windows console sets `TERM`.
`termcolor` has the asymmetry ripgrep inherits (`should_attempt_color` falls back
to `cfg!(windows)`), and the port had copied only its POSIX branch. Absent `TERM`
now suppresses on POSIX and does not on Windows.

The console-mode question is asked separately, and asked properly: Windows Terminal
arrives with VT processing enabled, legacy conhost has to be told, and
`std.Io.File.enableAnsiEscapeCodes` both tells it and answers whether it worked —
also recognizing a Cygwin/MSYS pty, which is not a console at all and which
`isTty` alone answers wrong. A console that refuses gets no escapes, since garbage
bytes read worse than plain text. An explicit `--color=always`/`ansi` still asks
the console to interpret, so a deliberate request renders instead of printing its
own escape sequences, and is still never vetoed. On POSIX the call degenerates to
the `isTty` it replaced, so that arm is unchanged byte for byte.

Also: `GIST_DIR` trailing-separator trimming only knew `/`, so a shell-completed
`C:\tmp\gist\` produced a doubled separator in every artifact path.
