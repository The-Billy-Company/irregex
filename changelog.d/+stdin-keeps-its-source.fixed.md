We keep a quiet pipe or socket as stdin, however long its producer takes. Empty
streams finish at EOF; an explicit first-byte timeout or a failed read returns
an error instead of searching the working directory or partial input.
