The row protocol now lives in `include/irregex.h` beside the status codes and
pattern flags: `irregex_row` / `irregex_rows` / `irregex_schema_*` / the four
`irregex_rows_*` walkers. Each product library still exports its own producer
(`gist_run`, `relate_run`, `blast_run`); they all hand back the same cursor, so
a host asking three packages three questions learns one way to read the answer.
