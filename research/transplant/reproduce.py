#!/usr/bin/env python3
"""Does the engine's persisted index survive a tree reproduction?

    ./reproduce.py <source-tree> [workdir]

A reproduction (`tar -x`, an OCI layer extraction, `rsync -t`, `cp -p`) creates
new inodes and restores mtime. POSIX requires the `utimensat(2)` that restores
mtime to mark ctime for update, and there is no call that sets ctime, so every
file lands with `mtime < anchor <= ctime` — which is exactly the band
`needsLiveRead` (mtime >= anchor OR ctime >= anchor) must treat as dirty. The
index then elides nothing while reporting itself healthy.

The phases model a container's life, in order: the image is built over a
snapshot, and the layer is extracted afterwards, onto a filesystem the build
never saw.

`os.utime(p, ns=(atime, mtime))` carrying the file's OWN mtime is not an
approximation of an extractor: it is the same single syscall, with the same
argument, which is the whole reason the ctime moves.

Wall time is reported but is not the claim. CPU-seconds are, because the
container this was found in shares a vCPU with four others, so CPU is what
multiplies into the subprocess timeout that surfaced the bug.

Reads nothing but the source tree, writes only inside `workdir`, and pins the
artifact-home variable there so it cannot disturb the index of the tree it copied.
"""

import os
import pathlib
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

PATTERN = r"pgxpool\.\w+"
RUNS = 5


def run(
    corpus: pathlib.Path, env: dict[str, str], *argv: str, trace: str = ""
) -> tuple[float, float, str]:
    """One child: wall seconds, its own CPU seconds, and its stderr."""
    child = env | ({"GIST_TRACE": trace} if trace else {})
    with open(os.devnull, "wb") as null:
        t0 = time.perf_counter()
        proc = subprocess.Popen(argv, cwd=corpus, env=child, stdout=null, stderr=subprocess.PIPE)
        err = proc.stderr.read() if proc.stderr else b""
        _, _, usage = os.wait4(proc.pid, 0)
        wall = time.perf_counter() - t0
    return wall, usage.ru_utime + usage.ru_stime, err.decode(errors="replace")


def measure(corpus: pathlib.Path, env: dict[str, str], label: str, *argv: str) -> None:
    walls, cpus = zip(
        *((w, c) for w, c, _ in (run(corpus, env, *argv) for _ in range(RUNS))),
        strict=True,
    )
    print(
        f"  {label:<38} wall {min(walls):5.3f}s   cpu {statistics.median(cpus):5.3f}s"
        f"   (cpu spread {min(cpus):.3f}–{max(cpus):.3f})"
    )


def candidates(corpus: pathlib.Path, env: dict[str, str]) -> str:
    """What the freshness sweep hands the engine — the pruning itself, not its cost.

    This is the column that decides the diagnosis: if the cover set moved between
    phases, the prefilter regressed and §2.2 is the wrong mechanism.
    """
    _, _, err = run(corpus, env, "gist", PATTERN, ".", trace="warm,index")
    keep = [
        line.strip()
        for line in err.splitlines()
        if any(k in line for k in ("candidate", "elide", "fresh", "anchor", "refresh"))
    ]
    return "\n    ".join(keep[:6]) or "(no trace lines matched)"


def reproduce(corpus: pathlib.Path) -> None:
    """Restore every file's own mtime — one `utimensat` each, as `tar -x` does."""
    n = 0
    for p in corpus.rglob("*"):
        if p.is_file() and ".gist" not in p.parts:
            st = p.stat()
            os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
            n += 1
    print(f"  reproduced {n} files — mtime preserved, ctime advanced by the kernel")


def clocks(corpus: pathlib.Path) -> None:
    """One file's two clocks, so the band the defect lives in is visible, not asserted."""
    p = next((q for q in corpus.rglob("*") if q.is_file() and ".gist" not in q.parts), None)
    if p is None:
        return
    st = p.stat()
    print(
        f"  sample {p.name}: mtime {st.st_mtime_ns / 1e9:.3f}  ctime {st.st_ctime_ns / 1e9:.3f}"
        f"  ctime>mtime {st.st_ctime_ns > st.st_mtime_ns}"
    )


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    source = pathlib.Path(argv[1]).expanduser().resolve()
    if not source.is_dir():
        print(f"not a directory: {source}", file=sys.stderr)
        return 1
    work = (
        pathlib.Path(argv[2]).expanduser()
        if len(argv) > 2
        else pathlib.Path(tempfile.mkdtemp(prefix="transplant-"))
    )
    corpus, gistdir = work / "corpus", work / "gistdir"
    env = os.environ | {"GIST_DIR": str(gistdir), "GIST_HINTS": "0", "GIST_NO_AUTOSERVE": "1"}

    print(f"\n0 · reproducing {source} into {corpus} (copy2: new inodes, mtime preserved)")
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(source, corpus, copy_function=shutil.copy2, symlinks=True, dirs_exist_ok=False)
    gistdir.mkdir(parents=True)

    print("\nA · no index at all — the state production was in before the fix")
    clocks(corpus)
    measure(corpus, env, "cold walk", "gist", PATTERN, ".")

    print("\nB · index built on this filesystem — what a laptop measures")
    run(corpus, env, "gist", "index", ".")
    print("    " + candidates(corpus, env))
    measure(corpus, env, "warm, indexed", "gist", PATTERN, ".")
    measure(corpus, env, "--no-index control", "gist", "--no-index", PATTERN, ".")

    print("\nC · that same index after a tree reproduction — production")
    reproduce(corpus)
    clocks(corpus)
    print("    " + candidates(corpus, env))
    measure(corpus, env, "warm, indexed (post-reproduction)", "gist", PATTERN, ".")
    measure(corpus, env, "--no-index control", "gist", "--no-index", PATTERN, ".")

    print("\nD · re-anchored on the filesystem it is queried on — the mitigation")
    t0 = time.perf_counter()
    _, cpu, _ = run(corpus, env, "gist", "index", ".")
    print(f"  re-anchor cost: wall {time.perf_counter() - t0:.2f}s  cpu {cpu:.2f}s")
    print("    " + candidates(corpus, env))
    measure(corpus, env, "warm, re-anchored", "gist", PATTERN, ".")
    print(f"\nworkdir kept at {work}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
