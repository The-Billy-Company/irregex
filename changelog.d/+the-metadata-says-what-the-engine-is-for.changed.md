The published metadata now says what this engine is for in the words somebody
types when they have the problem. PyPI and crates.io both score name, summary,
and keywords, and this package was spending all three on synonyms for its own
name: `regex`, `regexp`, `re`, `pattern`, `bindings`. `pattern` is a word every
crate in the category uses and `bindings` is what the category field already
says, so neither was doing any work.

The word that was missing is `redos`. Linear-time matching is the whole claim,
and "my regex hung the worker" is how the problem gets searched - so the summary
now leads with no catastrophic backtracking and no ReDoS rather than with the
implementation detail that the engine rides in the wheel. The README says it
too: the h1 carries the claim instead of just the package name, and the section
explaining `(a+)+b` now names the attack it is describing.

Also here: the trove classifiers grew the ones that were true and absent
(`Typing :: Typed`, since `py.typed` has always shipped; the three supported
operating systems; text-processing and indexing topics), the PyPI sidebar gained
Documentation and Changelog links, and crates.io gained `readme`, `homepage`,
`repository`, `documentation`, and three more categories. Nothing about the
engine moved - this is the packaging telling the truth louder.

One real fix rode along: the Python README claimed a 3.10 floor while
`requires-python` has said 3.12 since the PEP 695 syntax went in. A reader on
3.11 would have believed the README and gotten a resolver error.
