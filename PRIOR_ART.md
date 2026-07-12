# Gist prior art and scope

Gist is a local, regex-first code locator tuned for the repeated search loop of
coding agents. Its design combines a persistent byte-trigram candidate index,
freshness-aware fallback to current files, a linear-time verifier, ripgrep-like
CLI conventions, and compact definition-biased ranking.

That combination is the claim. The underlying techniques are established prior
art.

## Explicit non-claims

Gist is:

- **not a new indexing algorithm**; document and positional n-gram indexes have
  decades of literature and production use;
- **not full PCRE2**; lookaround, backreferences, and other PCRE2-only behavior
  fail loud;
- **not full Unicode rg (ripgrep) parity**; case folding plus `\b`/`\w` word
  semantics are ASCII-byte based;
- **not a semantic code-intelligence engine**; it does not resolve types,
  definitions, references, or call graphs;
- **not a Sourcegraph/Moderne replacement**; those systems cover hosted
  multi-repository search, permissions, semantic metadata, navigation,
  governance, and transformation workflows that Gist does not attempt.

`gist --schema` is authoritative for the narrower public compatibility
contract.

## Agent-search systems

### Cursor agent search

[Cursor's search documentation](https://cursor.com/docs/agent/tools/search)
describes an agent-selected combination of exact/regex search ("Instant Grep"),
semantic retrieval, and file reads. Its
[semantic-search report](https://cursor.com/blog/semsearch) evaluates hybrid
grep plus embedding retrieval for codebase questions.

Gist addresses only the deterministic exact/regex leg: local bytes, explicit
paths, current working-tree freshness, and CLI output. It neither reproduces
Cursor's proprietary implementation nor claims its semantic-retrieval role.

### Microsoft tgrep

[microsoft/tgrep](https://github.com/microsoft/tgrep) is a local,
trigram-indexed regex searcher with a client/server architecture, persistent
index, file watching, and a grep-shaped CLI. It is the closest public
agent-oriented design point. Gist differs in using a process-per-invocation
CLI, treating the index as optional read elision, and preserving a live-scan
fallback when index coverage or freshness is insufficient.

### Moderne Trigrep

[Moderne Trigrep](https://www.moderne.ai/moderne-agent-tools/trigrep) provides
sub-second, organization-scoped search across many repositories. Its
[official documentation](https://github.com/moderneinc/moderne-docs/blob/main/docs/user-documentation/agent-tools/trigrep.md)
describes Zoekt-compatible trigram indexes enriched from OpenRewrite Lossless
Semantic Trees, Sourcegraph/Zoekt query dialects, structural filters, CLI, and
MCP delivery.

Gist indexes local file bytes and adds lightweight byte-level ranking signals;
it has no LST, portfolio control plane, semantic filters, or transformation
engine.

## Indexed regex and code-search systems

### Google Code Search and csearch

Russ Cox's
[Regular Expression Matching with a Trigram Index](https://swtch.com/~rsc/regexp/regexp4.html)
explains required-trigram extraction, Boolean candidate queries, and regex
verification. The accompanying
[google/codesearch](https://github.com/google/codesearch) repository ships
`cindex` and `csearch`. This is direct algorithmic ancestry for Gist's basic
candidate-index design.

### Zoekt and Sourcegraph

[Zoekt](https://github.com/sourcegraph/zoekt) is a source-oriented search engine
with positional trigrams, mmap-friendly shards, Boolean queries, regex search,
ranking, multi-repository service components, and ctags-derived symbol signals;
its [design document](https://github.com/sourcegraph/zoekt/blob/main/doc/design.md)
details the index.

[Sourcegraph's architecture](https://sourcegraph.com/docs/admin/architecture)
places Zoekt inside a broader platform with repository synchronization,
permissions, unindexed fallback, code navigation, and service fan-out. Gist is
a local locator, not that platform.

### GitHub Blackbird

GitHub's
[Blackbird architecture article](https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/)
describes a Rust search engine using variable-length sparse n-grams, regex
planning, shard distribution, and global-scale constraints. Its
[history article](https://github.blog/engineering/architecture-optimization/a-brief-history-of-code-search-at-github/)
also documents blob-level deduplication and symbol metadata. Gist uses a much
simpler local fixed-trigram index and makes no Blackbird-scale claim.

### livegrep

[livegrep](https://github.com/livegrep/livegrep) provides interactive RE2 search
over prebuilt indexes through a long-running search backend and stateless web
front end. It targets shared, gigabyte-scale repositories; Gist targets a local
working tree and shells naturally from an agent loop.

### Hound

[Hound](https://github.com/hound-search/hound) builds and refreshes a trigram
index per repository behind a Go API and web UI, explicitly following Cox's
design. Gist reuses the same broad candidate-filter pattern without Hound's
repository service or browser interface.

### qgrep

[qgrep](https://github.com/zeux/qgrep) searches a compressed, incrementally
updated indexed copy of source data and supports content, path, and fuzzy file
queries. Gist instead keeps source files authoritative and uses its index to
avoid reads that cannot match.

## Semantic navigation and symbol indexes

These systems answer a different class of question from byte/regex search:

- [LSP 3.17](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
  standardizes live editor-to-language-server requests such as workspace
  symbols, definitions, references, and code actions.
- [LSIF](https://lsif.dev/) standardized persisted code-intelligence output and
  is now archived in favor of SCIP.
- [SCIP](https://github.com/scip-code/scip) is a language-agnostic persisted
  code-navigation protocol for definitions, references, and implementations.
- [Universal Ctags](https://github.com/universal-ctags/ctags) generates compact
  language-object tag indexes for symbol navigation.

Gist may rank text that looks like a declaration, but that heuristic is not
name resolution and must not be presented as semantic intelligence.

## Structural search and transformation

Text search is also distinct from syntax-aware matching and rewriting:

- [Semgrep](https://semgrep.dev/docs/contributing/semgrep-philosophy) matches
  code-shaped patterns for static analysis and bug/security variant detection.
- [ast-grep](https://ast-grep.github.io/) uses tree-sitter syntax trees for
  polyglot structural search, linting, and rewriting.
- [Comby](https://comby.dev/) uses lightweight language-aware templates for
  structural search and replacement across code and data formats.
- [OpenRewrite](https://docs.openrewrite.org/) applies recipes to
  format-preserving, type-attributed
  [Lossless Semantic Trees](https://docs.openrewrite.org/concepts-and-explanations/lossless-semantic-trees)
  for automated refactoring.

Gist deliberately remains a byte/regex locator. Agents should compose it with
these tools when the question is structural or transformational.

## N-gram and regex-index literature

The relevant research predates Gist and establishes both the design space and
its limits:

- Cho and Rajagopalan,
  [A Fast Regular Expression Indexing Engine](https://doi.org/10.1109/ICDE.2002.994755)
  (ICDE 2002), studies selective multi-gram indexes for regex filtering.
- Kim, Woo, Park, and Shim,
  [Efficient processing of substring match queries with inverted q-gram indexes](https://doi.org/10.1109/ICDE.2010.5447866)
  (ICDE 2010), studies posting-list plans for q-gram substring search.
- Cox's
  [trigram-index article](https://swtch.com/~rsc/regexp/regexp4.html) (2012)
  gives the direct code-search construction and open implementation.
- Google's
  [Software Engineering at Google, chapter 17](https://abseil.io/resources/swe-book/html/ch17.html)
  traces production Code Search from trigrams through suffix arrays to sparse
  n-grams and discusses the index-size/query-cost trade-off.
- Gibney and Thankachan,
  [Text Indexing for Regular Expression Matching](https://doi.org/10.3390/a14050133)
  (Algorithms 2021), gives conditional lower bounds and preprocessing/query
  trade-offs for general regex indexing.
- Zhang et al.,
  [An Evaluation of N-Gram Selection Strategies for Regular Expression Indexing](https://www.vldb.org/pvldb/vol18/p5703-zhang.pdf)
  (PVLDB 2025), compares modern n-gram selection strategies across contemporary
  workloads.

## Precise novelty statement

Gist's contribution is a **systems/workload composition** for one repository
and one high-frequency consumer: coding agents repeatedly issuing small
grep-shaped queries against a concurrently changing tree. It combines:

1. an optional persisted candidate index with fail-open live scanning;
2. a freshness overlay so unindexed edits stay visible;
3. a broad, explicit, fail-loud ripgrep-compatible CLI subset;
4. definition-biased, generated-code-aware ranking for bounded agent context;
5. reproducible correctness and cold-start performance gates.

None of those ingredients alone is novel. The value is integrating and
measuring them against the agent search loop without claiming the semantic,
hosted, Unicode, or regex breadth of the systems above.
