"""One module-level Pattern, many threads.

The C handle owns the scratch its finds run in, so two threads sharing one
corrupt a match rather than race a counter. A Python caller will not know that:
they will write ``PAT = irregex.compile(...)`` at module scope and hand it to a
pool. These tests are the proof that doing so is safe, and they are written so
that a binding sharing one handle would fail them rather than merely be slow.
"""

from __future__ import annotations

import gc
import threading
import weakref
from concurrent.futures import ThreadPoolExecutor

import irregex

# Compiled once, at module scope, exactly the way the hazard shows up in real
# code.
PATTERN = irregex.compile(r"(\w+)=(\d+)")

WORKERS = 16
ROUNDS = 120


def _one_worker(worker: int) -> None:
    # Every thread searches a different text, so a corrupted shared scratch
    # shows up as one thread reading another's spans - a wrong answer, not a
    # crash, which is why the assertion is on the content and not just the count.
    text = " ".join(f"k{worker}x{i}={worker * 1000 + i}" for i in range(12))
    expected = [(f"k{worker}x{i}", str(worker * 1000 + i)) for i in range(12)]
    for _ in range(ROUNDS):
        assert PATTERN.findall(text) == expected
        first = PATTERN.search(text)
        assert first is not None
        assert first.group(1) == f"k{worker}x0"
        assert text[first.start() : first.end()] == first.group(0)


def test_a_module_level_pattern_survives_a_thread_pool():
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for done in [pool.submit(_one_worker, w) for w in range(WORKERS)]:
            done.result()


def test_concurrent_finditer_on_different_texts_stays_correct():
    pattern = irregex.compile(r"\d+")
    barrier = threading.Barrier(WORKERS)
    problems: list[str] = []

    def run(worker: int) -> None:
        text = ("x" * worker) + "".join(f" {worker}{i} " for i in range(40))
        want = [f"{worker}{i}" for i in range(40)]
        barrier.wait()  # maximize the overlap rather than hoping for it
        for _ in range(60):
            got = [m.group() for m in pattern.finditer(text)]
            if got != want:
                problems.append(f"worker {worker} saw {got[:5]} wanted {want[:5]}")
                return

    threads = [threading.Thread(target=run, args=(w,)) for w in range(WORKERS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert problems == []


def test_each_thread_gets_its_own_handle():
    pattern = irregex.compile("abc")
    seen: list[int] = []
    lock = threading.Lock()
    # All eight threads must be alive at once while their addresses are read.
    # Left to run and exit one at a time, the freed handle's address is simply
    # handed back to the next thread's malloc, and the test would report
    # sharing where there is none.
    started = threading.Barrier(8)
    done = threading.Barrier(8)

    def note() -> None:
        pattern.is_match("abc")
        started.wait()
        with lock:
            seen.append(pattern._local.compiled.ptr.value)
        done.wait()

    threads = [threading.Thread(target=note) for _ in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert len(seen) == 8
    assert len(set(seen)) == 8, "two threads shared one C handle"


def test_a_short_lived_threads_handle_is_released_when_it_dies():
    # A pool of short-lived workers must not accumulate one live handle each.
    pattern = irregex.compile("abc")

    holder: list[weakref.ref] = []

    def work() -> None:
        pattern.is_match("abc")
        holder.append(weakref.ref(pattern._local.compiled))

    thread = threading.Thread(target=work)
    thread.start()
    thread.join()
    del thread
    gc.collect()

    assert holder and holder[0]() is None, "the dead thread's handle is still alive"


def test_results_match_a_single_threaded_run_exactly():
    text = " ".join(f"key{i}={i}" for i in range(200))
    sequential = PATTERN.findall(text)
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        parallel = [f.result() for f in [pool.submit(PATTERN.findall, text) for _ in range(64)]]
    assert all(one == sequential for one in parallel)
