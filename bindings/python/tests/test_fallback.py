"""One transport is enough, and declining the other has to actually work.

The parity proof lives next door in ``test_transport.py`` and needs both
implementations resident at once, so it is deselected on a ctypes-only run.
These two do not: they are about the shape of the fallback itself, they hold
whether or not an accelerator was ever compiled, and they therefore run on every
pass. That is deliberate - the property most worth guarding is that a machine
with no accelerator is a supported configuration rather than a degraded one, and
a test that can only run where the accelerator exists cannot say so.
"""

from __future__ import annotations

import os
import subprocess
import sys

from irgx import _engine


def test_the_package_answers_the_same_with_the_accelerator_declined():
    # A fresh interpreter, because the transport is chosen at import. Run for
    # real rather than asserted about: `IRGX_NO_ACCEL` is the switch CI flips to
    # run this whole suite twice, so it has to be the switch that works.
    program = (
        "import irgx;from irgx import _engine;"
        "print(_engine.native());"
        "print(irgx.findall(r'\\w+', 'a bc def'));"
        "print(irgx.compile_set(['a','b']).which('xbx'));"
        "print([t.patterns for t in [irgx.compile_munch([r'\\d+']).over('42').token(0)]])"
    )
    runs = {}
    for label, extra in (("on", {}), ("off", {"IRGX_NO_ACCEL": "1"})):
        done = subprocess.run(
            [sys.executable, "-c", program],
            capture_output=True,
            text=True,
            env=os.environ | extra,
            cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        )
        assert done.returncode == 0, done.stderr
        first, *rest = done.stdout.splitlines()
        runs[label] = (first, rest)

    assert runs["off"][0] == "()", "IRGX_NO_ACCEL left a native verb bound"
    assert runs["on"][1] == runs["off"][1], "the two transports answered differently"


def test_a_verb_with_no_native_implementation_still_has_one():
    # The routing is per verb, so an engine too old to export one symbol keeps
    # ctypes for that verb alone rather than losing the accelerator entirely.
    # This is the assertion that the fallback table is total.
    assert set(_engine.native()) <= set(_engine._FALLBACK)
    assert len(_engine._FALLBACK) == 14
    assert all(callable(fn) for fn in _engine._FALLBACK.values())
