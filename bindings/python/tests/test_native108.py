"""Exercise the additive limited-compile and Image1 ctypes declarations."""

from __future__ import annotations

import ctypes

from irgx import _abi


def test_image_record_layouts_preserve_every_header_field() -> None:
    limits = _abi.MunchImageLimits
    budget = _abi.MunchImageBudget
    assert ctypes.sizeof(limits) == 80
    assert ctypes.sizeof(budget) == 32
    assert [name for name, _ in limits._fields_] == [
        "struct_size",
        "version",
        "reserved0",
        "reserved1",
        "encoded_bytes",
        "decoded_bytes",
        "patterns",
        "voices",
        "states",
        "transition_entries",
        "auxiliary_entries",
        "live_owned_bytes",
    ]
    assert [getattr(limits, name).offset for name, _ in limits._fields_] == [
        0,
        4,
        8,
        12,
        16,
        24,
        32,
        40,
        48,
        56,
        64,
        72,
    ]
    assert [name for name, _ in budget._fields_] == [
        "struct_size",
        "version",
        "reserved0",
        "reserved1",
        "allocation_left",
        "work_left",
    ]
    assert [getattr(budget, name).offset for name, _ in budget._fields_] == [0, 4, 8, 12, 16, 24]


def test_limited_compile_binds_all_ceiling_words_and_the_output_pointer() -> None:
    handle = ctypes.c_void_p()
    try:
        assert (
            _abi.lib.irgx_compile_limited(
                b"a+", 2, _abi.PCRE, 100_000, 256, 1 << 20, ctypes.byref(handle)
            )
            == _abi.OK
        )
        assert handle.value is not None
        assert _abi.lib.irgx_is_match(handle, b"aaa", 3) == _abi.MATCH
    finally:
        if handle.value is not None:
            _abi.lib.irgx_free(handle)


def test_worker_clone_metered_scan_and_image_roundtrip_use_checked_records() -> None:
    patterns = (_abi.MunchPattern * 2)(_abi.MunchPattern(b"a+", 2), _abi.MunchPattern(b"ab", 2))
    original, worker, loaded = (ctypes.c_void_p() for _ in range(3))
    limits = _abi.MunchImageLimits(
        struct_size=ctypes.sizeof(_abi.MunchImageLimits),
        version=1,
        encoded_bytes=1 << 20,
        decoded_bytes=1 << 20,
        patterns=2,
        voices=64,
        states=1 << 16,
        transition_entries=1 << 20,
        auxiliary_entries=1 << 20,
        live_owned_bytes=1 << 24,
    )
    budget = _abi.MunchImageBudget(
        struct_size=ctypes.sizeof(_abi.MunchImageBudget),
        version=1,
        allocation_left=1 << 24,
        work_left=1 << 24,
    )
    try:
        assert _abi.lib.irgx_munch_compile(patterns, 2, 0, ctypes.byref(original)) == _abi.OK
        assert _abi.lib.irgx_munch_clone_worker(original, ctypes.byref(worker)) == _abi.OK
        token = _abi.MunchToken()
        winners = (ctypes.c_uint32 * 2)()
        remaining = ctypes.c_size_t(0)
        assert (
            _abi.lib.irgx_munch_scan_metered(
                worker,
                b"aaa",
                3,
                0,
                None,
                0,
                _abi.MUNCH_LONGEST,
                ctypes.byref(token),
                winners,
                2,
                ctypes.byref(remaining),
            )
            == _abi.OOM
        )
        assert (token.len, token.count, remaining.value) == (0, 0, 0)
        remaining.value = 100
        assert (
            _abi.lib.irgx_munch_scan_metered(
                worker,
                b"aaa",
                3,
                0,
                None,
                0,
                _abi.MUNCH_LONGEST,
                ctypes.byref(token),
                winners,
                2,
                ctypes.byref(remaining),
            )
            == _abi.MATCH
        )
        assert (token.len, token.count, winners[0]) == (3, 1, 0)
        assert remaining.value < 100

        written = ctypes.c_size_t()
        assert (
            _abi.lib.irgx_munch_save(
                worker, ctypes.byref(limits), ctypes.byref(budget), None, 0, ctypes.byref(written)
            )
            == _abi.MATCH
        )
        assert written.value > 0
        image = (ctypes.c_uint8 * written.value)()
        assert (
            _abi.lib.irgx_munch_save(
                worker,
                ctypes.byref(limits),
                ctypes.byref(budget),
                image,
                len(image),
                ctypes.byref(written),
            )
            == _abi.MATCH
        )
        assert (
            _abi.lib.irgx_munch_load(
                patterns,
                2,
                0,
                bytes(image),
                len(image),
                ctypes.byref(limits),
                ctypes.byref(budget),
                ctypes.byref(loaded),
            )
            == _abi.OK
        )
        assert (
            _abi.lib.irgx_munch_scan(
                loaded,
                b"aaa",
                3,
                0,
                None,
                0,
                _abi.MUNCH_LONGEST,
                ctypes.byref(token),
                winners,
                2,
            )
            == _abi.MATCH
        )
        assert (token.len, token.count, winners[0]) == (3, 1, 0)

        limits.struct_size -= 8
        refused = ctypes.c_void_p()
        assert (
            _abi.lib.irgx_munch_load(
                patterns,
                2,
                0,
                bytes(image),
                len(image),
                ctypes.byref(limits),
                ctypes.byref(budget),
                ctypes.byref(refused),
            )
            == _abi.INVALID
        )
        assert refused.value is None
    finally:
        for handle in (loaded, worker, original):
            if handle.value is not None:
                _abi.lib.irgx_munch_free(handle)
