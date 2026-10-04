We now check invalid patterns and fault recovery when validating native binding
archives. Those paths exercise thread-local error storage that a successful
match never reaches. Windows ARM64 has a hosted diagnostic that compares the
committed archive, compiler stripping and stripping after linking through the
actual C and Go consumers and the shared library.
