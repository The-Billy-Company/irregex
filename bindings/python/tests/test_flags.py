"""Every flag, proved by a behaviour that changes when it is set.

A flag test that only checks the bit word proves the binding can do arithmetic.
These check that the engine did something different, which is the only claim
worth making.
"""

from __future__ import annotations

import pytest

import irregex
from irregex import _abi
from irregex._pattern import flag_bits


def test_fixed_makes_the_pattern_literal():
    assert irregex.findall("a.c", "abc a.c") == ["abc", "a.c"]
    assert irregex.findall("a.c", "abc a.c", fixed=True) == ["a.c"]
    # A string full of metacharacters is a literal, not a syntax error.
    assert irregex.findall("(a+)[", "x (a+)[ y", fixed=True) == ["(a+)["]


def test_ignore_case_folds():
    assert irregex.findall("walrus", "WALRUS Walrus walrus") == ["walrus"]
    assert irregex.findall("walrus", "WALRUS Walrus walrus", ignore_case=True) == [
        "WALRUS",
        "Walrus",
        "walrus",
    ]


def test_word_requires_the_match_to_stand_alone():
    assert irregex.findall("cat", "cat concatenate cats") == ["cat", "cat", "cat"]
    assert irregex.findall("cat", "cat concatenate cats", word=True) == ["cat"]


def test_smart_case_folds_only_when_the_pattern_is_all_lowercase():
    assert irregex.findall("walrus", "WALRUS Walrus", smart_case=True) == ["WALRUS", "Walrus"]
    assert irregex.findall("Walrus", "WALRUS Walrus", smart_case=True) == ["Walrus"]


def test_unicode_is_on_by_default_and_can_be_turned_off():
    # `\w` covering `é` is the Unicode default; ASCII semantics split the run.
    assert irregex.findall(r"\w+", "café") == ["café"]
    assert irregex.findall(rb"\w+", "café".encode(), unicode=False) == [b"caf"]


def test_pcre_admits_grammar_the_linear_engine_refuses():
    with pytest.raises(irregex.error):
        irregex.compile(r"(\w)\1")
    assert irregex.findall(r"(\w)\1", "aabbc", pcre=True) == ["a", "b"]

    with pytest.raises(irregex.error):
        irregex.compile(r"(?<=@)\w+")
    assert irregex.findall(r"(?<=@)\w+", "me@example", pcre=True) == ["example"]


def test_fixed_wins_over_pcre_the_way_the_command_line_resolves_it():
    # A fixed string needs no engine, so the backend selector is inert rather
    # than contradicted; the pattern stays three literal bytes.
    assert irregex.findall("(?=x)", "a(?=x)b", fixed=True, pcre=True) == ["(?=x)"]


def test_the_bit_word_matches_the_header():
    assert flag_bits() == 0
    assert flag_bits(fixed=True) == 1 << 0
    assert flag_bits(ignore_case=True) == 1 << 1
    assert flag_bits(word=True) == 1 << 2
    assert flag_bits(smart_case=True) == 1 << 5
    # Unicode is the default, so the bit that exists is its absence.
    assert flag_bits(unicode=True) == 0
    assert flag_bits(unicode=False) == _abi.NO_UNICODE == 1 << 6
    assert flag_bits(pcre=True) == 1 << 8
    assert irregex.compile("a", word=True, ignore_case=True).flags == (1 << 1) | (1 << 2)


def test_a_misspelled_flag_is_refused_rather_than_ignored():
    with pytest.raises(TypeError):
        irregex.compile("a", ignorecase=True)
    with pytest.raises(TypeError):
        irregex.findall("a", "abc", ignore_cases=True)


def test_flags_cannot_be_passed_with_an_already_compiled_pattern():
    compiled = irregex.compile("a")
    with pytest.raises(ValueError):
        irregex.findall(compiled, "abc", ignore_case=True)
