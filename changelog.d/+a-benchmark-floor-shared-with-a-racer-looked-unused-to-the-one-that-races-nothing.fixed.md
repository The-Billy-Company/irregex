ShellCheck failed CI over `bench/apparatus/field.sh`, flagging `SCOPE` and
every `HAVE_*` availability flag as unused. Both are true and neither is a bug:
`field.sh` is vendored byte-identical across irregex/gist/relate/blast
(`bench/apparatus/SHARED.sha256`), and only gist's own
`bench/dominance/races/field.sh` sources it to build a rival-tool roster -
irregex mints no races of its own to read them back. ShellCheck cannot see a
downstream sourcer analyzing a file in isolation, so the same false positive
gist's `.shellcheckrc` already carries for this exact file is now disabled
here too, with the same reasoning recorded beside it.
