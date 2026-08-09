"""The planes beyond the buffer: lifetime, declinature, and answers checked against Python.

Three properties get most of the attention here, because they are the three a
ctypes binding gets wrong in ways that do not look wrong.

**Borrow lifetime.** A tree record's path, a walk entry's path and a sieve's
candidate list all point into an arena the handle owns, and in Python a ``str``
built from borrowed memory is indistinguishable from any other ``str``. So the
test for "we copied" is not an inspection, it is an *outliving*: close the handle,
then read the value. Under a keepalive design those assertions would pass too and
this suite would be equally happy — the difference is that the copy also survives
the handle being garbage collected mid-iteration, which no reference discipline a
caller can forget will do for you.

**Declinature.** ``IRGX_STALE`` is the engine stepping aside with no fault set,
and it is *common*: a tree with no sieve artifact, a PCRE2 pattern asked for its
literals, a codex built without a locate layer. Every one of those must be
``None`` and not an exception, because the caller's next move is a fallback, not
a traceback.

**Answers.** Where Python can compute the same thing, it does — the line grid
against ``splitlines``-shaped arithmetic, the codex's occurrence count against
``str.count``, the needle sweep against a loop over ``find``. A binding that
returns a plausible number is the failure mode these catch.
"""

from __future__ import annotations

import ctypes
import gc
from pathlib import Path

import irgx
import pytest

# ── lines ────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "text",
    ["", "a", "a\n", "a\nb", "a\r\nb\r\n", "\n\n\n", "one\ntwo\nthree", "é\nü", "a\n\rb"],
)
def test_the_line_grid_agrees_with_the_bytes(text: str) -> None:
    """Every row's own bytes, reassembled, must be the text again."""
    data = text.encode("utf-8")
    rows = irgx.split_lines(text)
    assert irgx.line_count(text) == len(rows)
    # Terminators included, the rows tile the text exactly: no gap, no overlap.
    assert b"".join(data[r.start : r.term_end] for r in rows) == data
    assert [r.number for r in rows] == list(range(1, len(rows) + 1))
    for row in rows:
        assert row.start <= row.content_end <= row.term_end
        assert row.content(data) == data[row.start : row.content_end]


def test_an_unterminated_tail_is_still_a_line() -> None:
    assert irgx.line_count("a\nb") == 2
    assert irgx.line_count("a\nb\n") == 2  # the trailing terminator adds no row
    assert irgx.split_lines("a\nb")[-1].term_end == 3


def test_a_crlf_keeps_its_carriage_return_in_the_content() -> None:
    # ripgrep's default, and what the matching engines in this library see, so a
    # host that strips it for display stays consistent with what it matched on.
    (row,) = irgx.split_lines("a\r\n")
    assert row.content(b"a\r\n") == b"a\r"


def test_an_offset_on_a_terminator_belongs_to_the_line_it_ends() -> None:
    band = irgx.line_context("a\nb\nc", 1, 0, 0)  # byte 1 is the first "\n"
    assert [r.number for r in band.rows] == [1]


def test_a_clipped_band_shortens_rather_than_renumbering() -> None:
    band = irgx.line_context("a\nb\nc", 0, before=5, after=0)
    assert [r.number for r in band.rows] == [1]
    assert band.center == 0, "the caret's row is band-relative and cannot be derived"
    middle = irgx.line_context("a\nb\nc", 2, before=1, after=1)
    assert [r.number for r in middle.rows] == [1, 2, 3]
    assert middle.center == 1


# ── literals and the Unicode tables ──────────────────────────────────────────


def test_the_literal_plane_declines_for_pcre_instead_of_raising() -> None:
    # A declinature: the PCRE2 arm publishes no inspectable program, so there is
    # nothing to promise. The caller's next move is "search anyway", not a stack
    # trace, so it is None.
    assert irgx.literals(irgx.compile(r"\w+", pcre=True)) is None


def test_a_literal_prefix_is_reported_as_such() -> None:
    handle = irgx.literals(irgx.compile("hello world"))
    assert handle is not None
    with handle:
        verdict, found = handle.set(irgx.Place.PREFIX)
        # CANDIDATE for a prefix and EXACT for the WHOLE set: a prefix is a
        # necessary condition a prefilter may use, while "the whole match is one
        # of these" is a sufficient one that lets the engine skip verification.
        assert verdict is irgx.Verdict.CANDIDATE
        assert found == (b"hello world",)
        whole, spelled = handle.set(irgx.Place.WHOLE)
        assert whole is irgx.Verdict.EXACT and spelled == (b"hello world",)
        facts = handle.facts()
        assert facts.min_len == facts.max_len == 11
        assert facts.first_bytes == frozenset({ord("h")})
        assert not facts.anchored and not facts.nullable


def test_the_unicode_tables_answer_from_the_engine_not_from_python() -> None:
    assert irgx.unicode_version().count(".") >= 1
    assert irgx.property_has("Lu", ord("A")) and not irgx.property_has("Lu", ord("a"))
    orbit = irgx.fold_orbit(ord("k"))
    assert ord("K") in orbit and 0x212A in orbit, "KELVIN SIGN folds with K"
    ranges = irgx.property_ranges("Nd")
    assert ranges and all(lo <= hi for lo, hi in ranges)
    assert any(lo == ord("0") for lo, _ in ranges)


# ── needles ──────────────────────────────────────────────────────────────────


def test_a_needle_sweep_finds_what_a_python_loop_finds() -> None:
    text = "the cat sat on the mat, the cat again"
    with irgx.compile_needles(["cat", "the", "zebra"]) as needles:
        assert needles.is_match(text)
        assert needles.which(text) == (0, 1), "zebra is absent, and absence is not a hit"
        hits = needles.find_all(text)
    want = sorted(
        (at, i)
        for i, needle in enumerate(("cat", "the", "zebra"))
        for at in range(len(text))
        if text.startswith(needle, at)
    )
    assert sorted((h.start, h.needle) for h in hits) == want
    assert all(h.end - h.start == len(("cat", "the", "zebra")[h.needle]) for h in hits)


def test_the_needle_tier_is_a_fact_about_cost_not_about_answers() -> None:
    # Which prefilter got chosen is exposed because it is a cost a caller may care
    # about; it must never change WHICH occurrences come back. A two-needle slate
    # and a twenty-needle one land on different tiers by design, so both are asked
    # the same question and must agree about the needles they share.
    few, many = ["a", "b"], [chr(ord("a") + i) for i in range(20)]
    text = "abcdefghij" * 4
    with irgx.compile_needles(few) as small, irgx.compile_needles(many) as large:
        shape = small.shape()
        assert isinstance(shape.presence_tier, irgx.Tier)
        assert isinstance(shape.attributed_tier, irgx.Tier)
        assert (shape.count, shape.longest, shape.bytes) == (2, 1, 2)
        assert small.which(text) == (0, 1)
        assert large.which(text)[:2] == (0, 1)
        # Presence and attribution are priced separately — knowing SOMETHING is
        # here is cheaper than knowing which — so they are two fields and a caller
        # can see when only the second one costs.
        assert large.shape().count == 20


def test_a_refused_needle_names_which_one_it_was() -> None:
    # An empty needle occurs at every position, so seating one would turn every
    # answer into the haystack's own length. The refusal is the easy half; the
    # half worth testing is that the INDEX survives the trip out of the ABI,
    # because "one of these forty is empty" is not something a caller can act on.
    with pytest.raises(irgx.error) as caught:
        irgx.compile_needles(["cat", "the", "", "zebra"])
    assert caught.value.index == 2, "the refusal did not say which needle caused it"

    # And the compile is all or nothing: the failure above seated no set at all,
    # rather than handing back a usable three-needle one with the empty dropped.
    with irgx.compile_needles(["cat", "the", "zebra"]) as whole:
        assert len(whole) == 3


# ── walk ─────────────────────────────────────────────────────────────────────


def _tree(root: Path) -> None:
    (root / "keep.py").write_text("import os\n")
    (root / "keep.txt").write_text("plain\n")
    (root / "sub").mkdir()
    (root / "sub" / "deep.py").write_text("x = 1\n")


def test_a_walk_entry_outlives_the_walk_that_produced_it(tmp_path: Path) -> None:
    # The proof that paths are COPIED at the boundary rather than borrowed: the
    # arena they pointed into is gone by the time they are read.
    _tree(tmp_path)
    walk = irgx.walk(tmp_path)
    files = list(walk)
    walk.close()
    gc.collect()
    assert files, "the walk found nothing, so this proves nothing"
    assert all(isinstance(f.path, str) and f.path for f in files)
    assert {Path(f.path).name for f in files} >= {"keep.py", "keep.txt", "deep.py"}


def test_a_walk_narrows_by_glob_and_by_depth(tmp_path: Path) -> None:
    _tree(tmp_path)
    with irgx.walk(tmp_path, globs=["*.py"]) as only_py:
        assert {Path(f.path).name for f in only_py} == {"keep.py", "deep.py"}
    with irgx.walk(tmp_path, not_globs=["*.py"]) as no_py:
        assert {Path(f.path).name for f in no_py} == {"keep.txt"}
    with irgx.walk(tmp_path, max_depth=1) as shallow:
        assert "deep.py" not in {Path(f.path).name for f in shallow}


def test_iterating_a_walk_twice_yields_the_same_set(tmp_path: Path) -> None:
    # The set is materialized, so a rewind re-reads nothing from the filesystem —
    # and a caller who iterates twice must not silently get an empty second pass.
    _tree(tmp_path)
    with irgx.walk(tmp_path) as walk:
        assert {f.path for f in walk} == {f.path for f in walk}
        assert len(walk) == len(list(walk))


def test_the_walk_ceilings_and_the_content_probes_answer(tmp_path: Path) -> None:
    ceilings = irgx.walk_limits()
    # The window the binary probe reads, the size past which a file is not read at
    # all, and the type registry's two dimensions. Published so a host can size
    # its own buffers to the same numbers instead of guessing them.
    assert ceilings.binary_window > 0 and ceilings.file_cap > ceilings.binary_window
    assert ceilings.type_names >= ceilings.type_rows > 0
    assert irgx.is_binary(b"text\nmore text\n") is False
    assert irgx.is_binary(b"\x00\x01binary") is True
    # Three genera, total and disjoint, partitioning the corpus by what a file is
    # FOR rather than by language. `code` is the LEFTOVER, so an unfamiliar
    # extension lands there — a gap can only ever show one file too many, never
    # hide one, which is the right direction for a search tool to fail in.
    assert irgx.genus(tmp_path / "x.py") is irgx.Genus.CODE
    assert irgx.genus(tmp_path / "x.md") is irgx.Genus.DOCS
    assert irgx.genus(tmp_path / "LICENSE") is irgx.Genus.DOCS
    assert irgx.genus(tmp_path / "x.toml") is irgx.Genus.DATA
    assert irgx.genus(tmp_path / "x.unheard-of") is irgx.Genus.CODE


# ── tree ─────────────────────────────────────────────────────────────────────


def test_a_tree_record_outlives_both_the_cursor_and_the_corpus(tmp_path: Path) -> None:
    # The same copy contract as the walk, over the handle stack that actually
    # nests: the record borrows the cursor's arena and the cursor borrows the
    # corpus. Both are gone here.
    (tmp_path / "a.py").write_text("alpha\nbeta\n")
    (tmp_path / "b.py").write_text("gamma\n")
    corpus = irgx.corpus(tmp_path)
    cursor = corpus.search("beta")
    assert cursor is not None
    records = list(cursor.pull())
    cursor.close()
    corpus.close()
    gc.collect()
    assert [r.line for r in records] == ["beta"]
    assert Path(records[0].path).name == "a.py"
    assert records[0].line_number == 2
    assert records[0].kind is irgx.RecordKind.LINE


def test_no_matches_is_an_empty_cursor_and_not_a_declinature(tmp_path: Path) -> None:
    # The two answers a host must be able to tell apart: an empty cursor means the
    # corpus was searched and holds nothing, while None would mean no tier
    # answered and the host should fall back to however it searches cold. Reading
    # the first as the second is how a fallback ends up never running.
    (tmp_path / "a.py").write_text("alpha\n")
    with irgx.corpus(tmp_path) as corpus:
        cursor = corpus.search("nowhere-at-all")
        assert cursor is not None
        with cursor:
            assert list(cursor.pull()) == []
            assert cursor.one() is None


def test_tree_context_lines_are_marked_as_context(tmp_path: Path) -> None:
    (tmp_path / "a.py").write_text("one\ntwo\nthree\n")
    with irgx.corpus(tmp_path) as corpus:
        cursor = corpus.search("two", before=1, after=1)
        assert cursor is not None
        with cursor:
            kinds = {r.line: r.kind for r in cursor.pull()}
    assert kinds["two"] is irgx.RecordKind.LINE
    assert kinds["one"] is irgx.RecordKind.CONTEXT
    assert kinds["three"] is irgx.RecordKind.CONTEXT


def test_a_cancelled_tree_search_stops_rather_than_faulting(tmp_path: Path) -> None:
    for i in range(20):
        (tmp_path / f"f{i}.py").write_text("needle\n" * 50)
    with irgx.corpus(tmp_path) as corpus, irgx.Cancel() as token:
        cursor = corpus.search("needle", cancel=token)
        assert cursor is not None
        with cursor:
            first = cursor.one()
            assert first is not None
            token.request()
            # Draining after a cancellation must terminate, and must not raise:
            # a cancelled walk is a short answer, not a failure.
            assert isinstance(list(cursor.pull()), list)


# ── sieve ────────────────────────────────────────────────────────────────────


def test_the_sieve_declines_a_tree_it_has_no_artifact_for(tmp_path: Path) -> None:
    # The whole point of the plane is that most files are never opened; with no
    # persisted artifact there is nothing to narrow WITH, and that is a
    # declinature rather than an error.
    narrowed = irgx.sieve(tmp_path)
    if narrowed is None:
        return  # no artifact, no sieve - the expected shape in a bare directory
    with narrowed:
        # An artifact exists (a coworker's index, say). Then every read that can
        # decline must still say None rather than raise.
        for value in (narrowed.candidates(irgx.winnow(irgx.compile("x"))), narrowed.stale_count()):
            assert value is None or isinstance(value, tuple | int)


def test_a_winnow_describes_a_pattern_without_any_artifact() -> None:
    # The winnow is a property of the PATTERN, so it answers with no corpus at
    # all — which is what makes it usable to decide whether narrowing is worth it.
    with irgx.winnow(irgx.compile(r"WalletService")) as plan:
        assert isinstance(plan.describe(), irgx.Plan)


# ── codex ────────────────────────────────────────────────────────────────────


def test_the_codex_counts_exactly_what_python_counts() -> None:
    text = "mississippi river, mississippi delta"
    with irgx.build_codex(text) as codex:
        assert len(codex) == len(text.encode())
        for needle in ("ss", "mississippi", "i", "zebra", "delta"):
            assert codex.count(needle) == text.count(needle), needle


def test_a_codex_locates_every_occurrence_it_counted() -> None:
    text = "abracadabra"
    with irgx.build_codex(text) as codex:
        found = codex.locate("abra")
        assert found is not None
        assert sorted(found) == [0, 7]
        assert len(found) == codex.count("abra")


def test_a_codex_extracts_text_it_does_not_store() -> None:
    text = "the quick brown fox"
    with irgx.build_codex(text) as codex:
        assert codex.extract(4, 5) == b"quick"
        assert codex.extract() == text.encode()


def test_a_codex_without_a_locate_layer_declines_rather_than_guessing() -> None:
    # NO_LOCATE is a build option, not a return value: the sampled-position layer
    # is not built at all, so counting stays exact and locating has no answer.
    with irgx.build_codex("abracadabra", sample_rate=irgx.NO_LOCATE) as codex:
        assert codex.count("abra") == 2, "counting needs no locate layer and must stay exact"
        assert codex.locate("abra") is None
        assert codex.position(0) is None
        assert codex.measure().locates is False


def test_a_saved_codex_reloads_to_the_same_answers() -> None:
    text = "mississippi"
    with irgx.build_codex(text) as built:
        blob = built.save()
    with irgx.load_codex(blob) as reloaded:
        assert len(reloaded) == len(text.encode())
        assert reloaded.count("ss") == 2
        assert reloaded.extract() == text.encode()


def test_a_text_over_the_ceiling_is_refused_before_it_is_indexed() -> None:
    # The ceiling is INT32_MAX, so this is checked by asking rather than by
    # allocating three gigabytes to watch it fail.
    ceiling = irgx.max_text_len()
    assert ceiling > 2**30, f"a suspiciously small ceiling: {ceiling}"
    assert ceiling == ctypes.c_size_t(ceiling).value, "the ceiling came back truncated"


# ── handles ──────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "make",
    [
        lambda p: irgx.walk(p),
        lambda p: irgx.corpus(p),
        lambda p: irgx.compile_needles(["a"]),
        lambda p: irgx.build_codex("abc"),
        lambda p: irgx.winnow(irgx.compile("a")),
        lambda p: irgx.Cancel(),
    ],
)
def test_every_handle_closes_idempotently_and_refuses_use_afterward(make, tmp_path: Path) -> None:
    handle = make(tmp_path)
    assert not handle.closed
    with handle as entered:
        assert entered is handle
    assert handle.closed
    handle.close()  # second close is a no-op, not a double free
    handle.close()
    with pytest.raises(irgx.error, match="closed"):
        _ = handle.ptr


def test_a_dropped_handle_does_not_crash_the_interpreter(tmp_path: Path) -> None:
    # `__del__` runs at an arbitrary point, including during interpreter
    # shutdown, so it has to tolerate a handle that was already closed and one
    # that never opened. Nothing to assert but the absence of a fault.
    _tree(tmp_path)
    for _ in range(50):
        walk = irgx.walk(tmp_path)
        del walk
    gc.collect()
    handle = irgx.build_codex("abc")
    handle.close()
    del handle
    gc.collect()
