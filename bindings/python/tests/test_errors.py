"""Failures arrive as exceptions carrying a reason, never as a wrong answer.

The C ABI reports in status codes, and the one thing a binding must never do
with a negative status is let it become a plausible-looking result. Every test
here checks both halves: that the call raised, and that what it raised says
enough to act on.
"""

from __future__ import annotations

import ctypes
import gc
import importlib.machinery
import pathlib
import subprocess
import sys
import sysconfig

import pytest

import irregex
from irregex import _abi


@pytest.mark.parametrize(
    "pattern",
    [
        "(",
        "[a-",
        "*abc",
        "a{2,1}",
        "[z-a]",
        "\\",
    ],
)
def test_a_pattern_the_engine_refuses_raises_error(pattern):
    with pytest.raises(irregex.error) as caught:
        irregex.compile(pattern)
    message = str(caught.value)
    # The message has to name the offending pattern - a caller compiling
    # patterns out of a config file has no other way to tell which one broke -
    # and give the engine's own reason rather than a bare status number.
    assert repr(pattern) in message
    assert "could not compile" in message
    assert message.strip() != "could not compile"


def test_the_reason_comes_from_the_engine_not_from_this_binding():
    with pytest.raises(irregex.error) as caught:
        irregex.compile("(")
    # `BadPattern` is the fault name the engine records; `invalid` is its status
    # sentence. Both come across the ABI, and neither is decided in this package.
    message = str(caught.value)
    assert "BadPattern" in message
    assert _abi._status_text(_abi.INVALID) in message


def test_a_declined_pattern_reports_the_engines_own_declinature():
    with pytest.raises(irregex.error) as caught:
        irregex.compile("(?=x)")
    # A different status, so a different sentence - and it is the engine's, not
    # a phrase this package made up to stand in for one.
    assert _abi._status_text(_abi.STALE) in str(caught.value)


def test_error_is_catchable_the_way_re_error_is():
    # The class is named `error` so that `except re.error:` ports to
    # `except irregex.error:` with no other edit.
    assert irregex.error.__name__ == "error"
    assert issubclass(irregex.error, Exception)
    try:
        irregex.compile("(")
    except irregex.error:
        pass
    else:
        pytest.fail("a broken pattern compiled")


def test_lookaround_is_refused_by_name_until_pcre_is_asked_for():
    with pytest.raises(irregex.error):
        irregex.compile(r"(?=foo)")
    # And the same pattern is fine once the caller opts into the other engine,
    # so the refusal is about grammar and not about the pattern being nonsense.
    assert irregex.compile(r"(?=foo)", pcre=True).is_match("foo")


# Well-formed patterns that the linear grammar has no way to express -
# lookahead, lookbehind, a backreference, an atomic group - and that the PCRE2
# arm compiles as they stand. The engine DECLINES these rather than failing
# them, which is the whole reason the binding can tell them apart.
NEEDS_PCRE = ("(?=x)", "(?<=x)y", r"(a)\1", "(?>ab)")

# Patterns no grammar here accepts. `pcre=True` is not a remedy for any of them.
MALFORMED = ("(unclosed", "a{2,1}", "[z-a]", "*x", "[abc")


@pytest.mark.parametrize("pattern", NEEDS_PCRE)
def test_a_pattern_only_the_other_grammar_can_express_says_so_in_its_class(pattern):
    with pytest.raises(irregex.UnsupportedPattern) as caught:
        irregex.compile(pattern)
    # A class of its own is what makes this actionable: a caller can catch it
    # and retry, where one shared exception type left them parsing prose.
    assert issubclass(irregex.UnsupportedPattern, irregex.error)
    # Nothing is wrong anywhere in the pattern, so there is no place to point at.
    assert caught.value.pos is None
    assert caught.value.pattern == pattern
    # And the message says the remedy outright, for the caller who only ever
    # reads the traceback.
    assert "pcre=True" in str(caught.value)


@pytest.mark.parametrize("pattern", NEEDS_PCRE)
def test_a_declinature_files_no_fault_which_is_why_the_status_has_to_carry_it(pattern):
    # Fail a pattern first, so the thread's fault slot holds something a binding
    # could mistake for this one's account of itself.
    with pytest.raises(irregex.error):
        irregex.compile("[abc")
    assert _abi._fault() is not None

    with pytest.raises(irregex.UnsupportedPattern):
        irregex.compile(pattern)
    # A tier that stepped aside files nothing, and clears what was there rather
    # than leaving the last failure standing. So there is no name here to match
    # on: a binding that classified by fault name would have had nothing to read
    # and would have called this a plain error. The status code is the answer.
    assert _abi._fault() is None


@pytest.mark.parametrize("pattern", NEEDS_PCRE)
def test_a_declined_compile_leaves_no_half_built_pattern_behind(pattern):
    irregex.purge()
    # The engine leaves `*out` untouched when it declines, so the object under
    # construction never receives a handle. Doing it many times over would take
    # the process down if teardown freed that slot anyway, and would exhaust the
    # cache if a raising compile were memoized.
    for _ in range(64):
        with pytest.raises(irregex.UnsupportedPattern):
            irregex.compile(pattern)
        with pytest.raises(irregex.UnsupportedPattern):
            irregex.is_match(pattern, "x")
    gc.collect()
    # Nothing usable escaped, and nothing poisoned: the same source still
    # compiles under the flag it was asking for, and still searches.
    rescued = irregex.compile(pattern, pcre=True)
    assert rescued.pattern == pattern
    assert isinstance(rescued.is_match("x"), bool)


@pytest.mark.parametrize("pattern", NEEDS_PCRE)
def test_the_remedy_the_message_names_actually_works(pattern):
    # The claim in the message is only worth making if it holds, so the suite
    # makes it the same way a caller would.
    assert isinstance(irregex.compile(pattern, pcre=True), irregex.Pattern)


@pytest.mark.parametrize("pattern", MALFORMED)
def test_a_malformed_pattern_stays_plain_error_and_says_where(pattern):
    with pytest.raises(irregex.error) as caught:
        irregex.compile(pattern)
    # Not the subclass: promising `pcre=True` here would send the caller down a
    # road that ends in the same exception.
    assert not isinstance(caught.value, irregex.UnsupportedPattern)
    where = caught.value.pos
    assert isinstance(where, int)
    # A refusal detected at the end of the pattern points one past the last
    # byte, which is still an offset into it rather than into anything else.
    assert 0 <= where <= len(pattern)
    assert caught.value.pattern == pattern


@pytest.mark.parametrize("pattern", MALFORMED)
def test_asking_for_pcre_does_not_rescue_a_malformed_pattern(pattern):
    with pytest.raises(irregex.error) as caught:
        irregex.compile(pattern, pcre=True)
    assert not isinstance(caught.value, irregex.UnsupportedPattern)


@pytest.mark.parametrize("pattern", NEEDS_PCRE + MALFORMED)
def test_except_error_still_catches_every_refusal(pattern):
    # The subclass is additive: code that only knows `irregex.error` - which is
    # every caller written before it existed - keeps catching both kinds.
    with pytest.raises(irregex.error):
        irregex.compile(pattern)


def test_a_refusal_carries_the_pattern_the_caller_spelled():
    # `re.error` carries msg/pattern/pos, and a caller compiling patterns out of
    # a config file needs all three to report which line was wrong.
    with pytest.raises(irregex.error) as caught:
        irregex.compile("[abc")
    assert (caught.value.msg, caught.value.pattern, caught.value.pos) == (
        str(caught.value),
        "[abc",
        4,
    )
    # A bytes pattern comes back as bytes, not as a decoding of them.
    with pytest.raises(irregex.error) as from_bytes:
        irregex.compile(b"[abc")
    assert from_bytes.value.pattern == b"[abc"


def test_oom_becomes_memory_error():
    # There is no way to make the engine run out of memory on demand, so this
    # exercises the translation directly: a Python caller already writes
    # `except MemoryError`, and mapping IRREGEX_OOM anywhere else would make
    # that handler dead code.
    with pytest.raises(MemoryError):
        _abi.check(_abi.OOM, "while pretending to allocate")
    with pytest.raises(irregex.error):
        _abi.check(_abi.INVALID, "while pretending to compile")
    assert _abi.check(_abi.MATCH, "unused") == _abi.MATCH
    assert _abi.check(_abi.OK, "unused") == _abi.OK


def test_a_declinature_from_a_verb_that_has_no_fallback_is_not_success():
    # `check` translates every verb except the one that declines, and compile
    # takes its own fallback before getting here. So a stale arriving at this
    # function is a verb that grew one this binding cannot take - which must be
    # loud, since returning it would hand back a status meaning "no result" as
    # though it were one.
    with pytest.raises(irregex.error) as caught:
        _abi.check(_abi.STALE, "while pretending to search")
    assert _abi._status_text(_abi.STALE) in str(caught.value)
    # And not as the retryable kind: there is no pcre=True to suggest here.
    assert not isinstance(caught.value, irregex.UnsupportedPattern)


def test_mixing_str_and_bytes_raises_type_error_not_a_wrong_answer():
    text_pattern = irregex.compile(r"\w+")
    byte_pattern = irregex.compile(rb"\w+")

    with pytest.raises(TypeError) as caught:
        byte_pattern.search("abc")
    assert "bytes" in str(caught.value)

    with pytest.raises(TypeError):
        text_pattern.search(b"abc")
    with pytest.raises(TypeError):
        text_pattern.sub("x", b"abc")
    with pytest.raises(TypeError):
        text_pattern.split(b"abc")


def test_searching_something_that_is_not_text_at_all():
    pattern = irregex.compile(r"\w+")
    for subject in (42, None, ["a"], object()):
        with pytest.raises(TypeError):
            pattern.search(subject)


def test_a_pattern_that_is_not_text_at_all():
    for source in (42, None, ["a"]):
        with pytest.raises(TypeError):
            irregex.compile(source)


def test_group_asked_for_by_the_wrong_kind_of_key():
    match = irregex.search(r"(a)", "a")
    with pytest.raises(TypeError):
        match.group(1.5)


def _import_with_library(path: str) -> subprocess.CompletedProcess[str]:
    """Import the package in a fresh interpreter with ``IRREGEX_LIB`` set.

    Loading happens at import, so every load-time failure has to be observed
    from outside this process.
    """
    return subprocess.run(
        [sys.executable, "-c", "import irregex"],
        env={"IRREGEX_LIB": path, "PATH": "/usr/bin:/bin"},
        capture_output=True,
        text=True,
        cwd=str(pathlib.Path(__file__).resolve().parents[1]),
        check=False,
    )


def test_a_missing_library_says_so_and_names_the_path():
    # "cannot load library" with no path is the unhelpful version of this
    # error, and the one a caller who mistyped IRREGEX_LIB cannot act on.
    done = _import_with_library("/nonexistent/libirregex.dylib")
    assert done.returncode != 0
    assert "/nonexistent/libirregex.dylib" in done.stderr


def test_a_file_that_is_not_a_shared_library_at_all_is_refused_at_load():
    done = _import_with_library(__file__)
    assert done.returncode != 0
    assert "could not load the irregex library" in done.stderr


def _some_other_shared_library() -> str | None:
    """Any real extension module file, which certainly is not libirregex.

    Discovered from the interpreter's own search paths rather than named: a
    statically linked module (`_ctypes` on the CPython builds uv ships) has no
    `__file__` to point at, and which modules are separate objects is a property
    of the build, not something a test may assume.
    """
    suffixes = tuple(importlib.machinery.EXTENSION_SUFFIXES)
    seen: set[str] = set()
    for key in ("stdlib", "platstdlib", "platlib"):
        root = sysconfig.get_path(key)
        if not root or root in seen:
            continue
        seen.add(root)
        for path in sorted(pathlib.Path(root).rglob("*")):
            if path.name.endswith(suffixes) and path.is_file():
                return str(path)
    return None


def test_a_shared_library_that_is_not_libirregex_is_refused_at_load():
    # ctypes will load any shared object without complaint. Binding a name that
    # is not there is where it would otherwise fail: much later, in the middle
    # of a search, and with nothing pointing back at the real mistake. A CPython
    # extension module is a real loadable object that certainly does not export
    # the regex plane, so it stands in for a wrong library here.
    other = _some_other_shared_library()
    if other is None:
        pytest.skip("no dynamically loaded extension module to stand in for a wrong library")
    done = _import_with_library(other)
    assert done.returncode != 0
    assert "does not export irregex_abi_version" in done.stderr


def test_the_abi_version_is_checked_and_this_build_speaks_it():
    assert _abi.ABI_VERSION == 2
    assert _abi.lib.irregex_abi_version() == 2


def test_a_refusal_measures_its_offset_in_the_pattern_and_says_so():
    # `pos` used to be inferred - an offset counted as a pattern offset because
    # no path came back with it - so a fault that grew a path would have started
    # pointing a caret into the wrong string. The fault names its own ruler now,
    # and `pos` is the one ruler this plane can report in.
    with pytest.raises(irregex.error) as caught:
        irregex.compile("[abc")
    detail = _abi.Fault()
    detail.struct_size = ctypes.sizeof(_abi.Fault)
    assert _abi.lib.irregex_last_fault(ctypes.byref(detail)) == _abi.MATCH
    assert detail.at_space == _abi.AT_PATTERN
    # No file is involved in compiling a pattern, which is exactly the
    # conjunction the reader no longer has to make for itself.
    assert not detail.path
    assert caught.value.pos == detail.at
