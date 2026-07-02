**`rg` gains `--color` support and match highlighting — the one CLI feature
demo'd against real ripgrep that gist visibly lacked** (`color.zig` (new),
`output.zig`, `run.zig`, `args.zig`, `cli/main.zig`). `--color=always`/`ansi`
previously failed loud (`unsupported by design — gist emits no ANSI`); the
default `auto` mode silently emitted nothing. Both are now real, resolved once
per run in the new `color.zig`.

- **`--color auto|always|never|ansi`**, matching ripgrep's own resolution
  rules: `auto` (the default) colorizes iff stdout is a real terminal *and*
  the environment doesn't opt out (`NO_COLOR` — any value, https://no-color.org
  — or an absent/`dumb` `TERM`) *and* no flag that implies plain text
  (`--json`, `--vimgrep`) is active; `always`/`ansi` force it on regardless of
  destination or environment (rg's own override rule — an explicit request
  beats `NO_COLOR`); `never` forces it off.
- **Match highlighting tuned to beat ripgrep's own default on legibility, not
  just parity**: rg's `fg:red,style:bold` is the "normal" red (SGR `31`),
  which reads muddy against a lot of terminal palettes. gist paints a match
  bold + underlined *bright* red (`1;4;91`) — still coloring the letters, no
  filled background block — so it reads at a glance without inventing a new
  visual language. Path (bold magenta) and line-number (green) keep rg's own
  hues; separators are dimmed one notch so the match is the only thing
  competing for the eye. Wired through every text-emitting path: the default
  `path:line:text` frame, `-o`/`--only-matching`, `--vimgrep`, `--passthru`,
  and `-w` word-bounded spans (an `-r`/`--replace` line is left unpainted —
  the substituted text isn't "the match" any more).

**Proof:** piped/non-tty output — the common agent-loop case, and the whole
point of the earlier stdin-parity work — is untouched: `color.enabled`
resolves to `false` whenever stdout isn't a real terminal, so `make | gist
"pat"` stays byte-identical to `make | rg "pat"`. `--color=always` verified
against real `rg --color=always` on the same fixture (`-n`, `-o`, `-w`): the
path/line-number/match ANSI runs decode correctly and non-tty parity holds
with color forced off.
