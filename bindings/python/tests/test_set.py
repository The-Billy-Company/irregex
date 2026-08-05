"""What a set of patterns must answer: exactly what the patterns answer alone.

There is no ``re`` counterpart to differ from, so the oracle here is the
binding's own single-pattern plane. That is the property :class:`irgx.PatternSet`
promises - one pass over the text names the same patterns N passes would - and it
is the one a caller silently loses if the engine's multi-pattern prefilter ever
over-rejects. So most of this file is that comparison, over a corpus chosen for
the cases a prefilter is likeliest to get wrong: anchors, a nullable pattern, a
word boundary, a non-ASCII literal, and a pattern that matches nothing.
"""

from __future__ import annotations

import itertools
import threading

import irgx
import pytest

PATTERNS = (r"^b", r"c$", r"a\sb", r"x*", r"\bcat\b", r"\d+", "héllo", "q")

TEXTS = (
    "",
    "abc",
    "a\nb",
    "ab\ncd",
    "\n",
    "abc\n",
    "b",
    "a cat sat",
    "concatenate",
    "42",
    "héllo",
    "no match here",
)


def one_at_a_time(patterns, text, **flags):
    """Which patterns match, asked of one compiled pattern at a time.

    Through the module-level verb rather than ``irgx.compile``, so the oracle
    reuses its cached patterns instead of recompiling eight of them per text -
    the subset test below asks this a few thousand times.
    """
    return [i for i, p in enumerate(patterns) if irgx.is_match(p, text, **flags)]


# ── the property ──────────────────────────────────────────────────────────


@pytest.mark.parametrize("text", TEXTS)
def test_a_set_names_what_the_patterns_name_alone(text):
    kinds = irgx.compile_set(PATTERNS)
    assert kinds.which(text) == one_at_a_time(PATTERNS, text)


@pytest.mark.parametrize("text", TEXTS)
def test_the_boolean_agrees_with_the_attribution(text):
    # `is_match` is a different engine path - it may answer from a literal scan
    # with no pattern running - so it is asked rather than derived.
    kinds = irgx.compile_set(PATTERNS)
    assert kinds.is_match(text) == bool(kinds.which(text))


def test_every_subset_agrees_too():
    """The same claim under composition.

    A slate's prefilter is built out of the patterns it holds, so removing one
    changes how the others are searched for: a set that is right at full
    membership can still be wrong at a subset. 255 subsets is cheap enough to
    just do all of them.
    """
    for size in range(1, len(PATTERNS) + 1):
        for chosen in itertools.combinations(PATTERNS, size):
            kinds = irgx.compile_set(chosen)
            for text in TEXTS:
                assert kinds.which(text) == one_at_a_time(chosen, text), (chosen, text)


def test_the_unit_is_the_whole_text_not_a_line():
    """Anchors mean the ends of the text, as they do for a lone pattern.

    The engine's slate kernel also has a per-LINE face, which is the right unit
    for a grep walking a corpus and the wrong one here; this is the test that
    fails if the ABI is ever pointed at it.
    """
    kinds = irgx.compile_set((r"^b", r"b$"))
    assert kinds.which("a\nb\nc") == []
    assert kinds.which("b\nb") == [0, 1]


def test_a_nullable_pattern_matches_the_empty_text():
    assert irgx.compile_set((r"x*",)).which("") == [0]
    assert irgx.compile_set((r"x+",)).which("") == []


# ── flags ─────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("flags", "patterns", "text", "want"),
    [
        ({"ignore_case": True}, ("abc", "xyz"), "ABC", [0]),
        ({}, ("abc", "xyz"), "ABC", []),
        ({"word": True}, ("cat", "dog"), "concatenate", []),
        ({}, ("cat", "dog"), "concatenate", [0]),
        ({"fixed": True}, ("a.c", "x*"), "abc", []),
        ({"fixed": True}, ("a.c", "x*"), "a.c x*", [0, 1]),
        # smart_case resolves per PATTERN, against that pattern's own spelling,
        # so one set can hold a folded pattern and a case-sensitive one.
        ({"smart_case": True}, ("abc", "ABC"), "AbC", [0]),
        ({"unicode": False}, (r"\w+",), "héllo", [0]),
    ],
)
def test_the_flags_reach_every_pattern(flags, patterns, text, want):
    assert irgx.compile_set(patterns, **flags).which(text) == want
    # And the same flags through the single-pattern door agree.
    assert one_at_a_time(patterns, text, **flags) == want


def test_pcre_is_a_set_wide_choice():
    kinds = irgx.compile_set((r"a", r"c(?=at)"), pcre=True)
    assert kinds.which("a cat") == [0, 1]
    assert kinds.which("cot") == []


@pytest.mark.parametrize("flag", ["multiline", "dotall"])
def test_the_two_flags_a_set_cannot_carry_are_refused(flag):
    # Refused rather than ignored: a caller who passed one believes something
    # about the answer they are about to get.
    with pytest.raises(ValueError, match=flag):
        irgx.compile_set(("a",), **{flag: True})


def test_an_unknown_flag_is_a_typo_not_a_default():
    with pytest.raises(TypeError):
        irgx.compile_set(("a",), ignorecase=True)


# ── refusals ──────────────────────────────────────────────────────────────


def test_a_malformed_pattern_names_its_index():
    with pytest.raises(irgx.error) as caught:
        irgx.compile_set((r"a", r"b", r"c("))
    assert caught.value.index == 2
    assert caught.value.pattern == r"c("
    # The position is the engine's, in the pattern that has it.
    assert caught.value.pos is not None


def test_a_pattern_needing_pcre_declines_by_index_and_the_flag_rescues_it():
    with pytest.raises(irgx.UnsupportedPattern) as caught:
        irgx.compile_set((r"a", r"c(?=at)"))
    assert caught.value.index == 1
    assert caught.value.pattern == r"c(?=at)"
    # And it is still an `irgx.error`, so a caller who catches only that one
    # still catches this.
    assert isinstance(caught.value, irgx.error)
    assert irgx.compile_set((r"a", r"c(?=at)"), pcre=True).which("cat") == [0, 1]


def test_a_lone_pattern_carries_no_index():
    with pytest.raises(irgx.error) as caught:
        irgx.compile(r"c(")
    assert caught.value.index is None


# ── shape ─────────────────────────────────────────────────────────────────


def test_an_empty_set_answers_rather_than_refusing():
    # The natural shape of a config file that listed no patterns.
    empty = irgx.compile_set([])
    assert len(empty) == 0
    assert empty.patterns == ()
    assert not empty.is_match("anything")
    assert empty.which("anything") == []


def test_introspection():
    kinds = irgx.compile_set((r"a", r"b+"))
    assert len(kinds) == 2
    assert kinds.patterns == (r"a", r"b+")
    assert kinds.flags == irgx.compile(r"a").flags
    assert not kinds.is_bytes
    assert repr(kinds) == "irgx.compile_set(['a', 'b+'])"


def test_a_generator_of_patterns_is_accepted():
    kinds = irgx.compile_set(p for p in ("a", "b"))
    assert kinds.patterns == ("a", "b")


# ── the str/bytes discipline ──────────────────────────────────────────────


def test_a_bytes_set_searches_bytes():
    kinds = irgx.compile_set((rb"^b", rb"c$"))
    assert kinds.is_bytes
    assert kinds.which(b"bc") == [0, 1]


def test_the_two_domains_do_not_mix():
    with pytest.raises(TypeError, match="mixture"):
        irgx.compile_set(("a", b"b"))
    with pytest.raises(TypeError, match="compiled from str"):
        irgx.compile_set(("a",)).which(b"a")
    with pytest.raises(TypeError, match="compiled from bytes"):
        irgx.compile_set((b"a",)).which("a")
    with pytest.raises(TypeError, match="must be str or bytes"):
        irgx.compile_set((42,))
    with pytest.raises(TypeError, match="expected str or bytes"):
        irgx.compile_set(("a",)).is_match(42)


def test_a_str_set_reads_the_text_as_utf8():
    # No offsets come back from a set, so the two domains only have to agree
    # about what matched - which they do, because the same bytes are searched.
    kinds = irgx.compile_set(("héllo", "wörld"))
    assert kinds.which("héllo wörld") == [0, 1]
    assert irgx.compile_set(("héllo".encode(),)).which("héllo".encode()) == [0]


# ── concurrency ───────────────────────────────────────────────────────────


def test_a_set_is_shareable_across_threads():
    """One handle per thread, exactly as a Pattern does it.

    The handle owns the scratch its scans run in, so a shared one would corrupt
    an answer rather than race a counter.
    """
    kinds = irgx.compile_set(PATTERNS)
    want = {text: kinds.which(text) for text in TEXTS}
    failures: list[str] = []

    def hammer() -> None:
        for _ in range(50):
            for text in TEXTS:
                if kinds.which(text) != want[text]:
                    failures.append(text)
                    return

    threads = [threading.Thread(target=hammer) for _ in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert not failures
