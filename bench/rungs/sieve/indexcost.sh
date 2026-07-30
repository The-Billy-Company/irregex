#!/usr/bin/env bash
# gist bench — Layer L's **index cost** arm: what each of the two trigram
# indexes charges for the selectivity it delivers.
#
# Selectivity is only half of "is this index better". An index that admits
# fewer candidate bytes by being four times the size and four times slower to
# build has not won anything, so Layer L is fail-closed on cost as well as on
# candidates (`certify_indexq_report.py` refuses to splice a win outside the
# declared cost envelope). This script measures the cost half.
#
# Fairness is not re-litigated here: `bench/races/_compete.sh` already owns the
# contract that csearch indexes gist's EXACT corpus — the persisted
# `paths.list`, the doc→path table gist's own indexer emitted — so the two
# indexes cover byte-identical files. This script SOURCES that file (it is a
# library, never executed) and reuses its paths and its `cindex` invocation
# verbatim rather than keeping a second, driftable copy.
#
# Emits a two-row TSV (`indexcost.tsv`) that the reporter reads. Peak RSS comes
# from the kernel via `/usr/bin/time` (`-l` on BSD/macOS, `-v` on GNU), in KiB
# on GNU and bytes on BSD — normalized to bytes here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../dominance/races/field.sh
source "${HERE}/../../dominance/races/field.sh"

OUT_TSV="${OUT}/indexcost.tsv"
mkdir -p "${COMPETE_DIR}" "${OUT}"

[[ -f "${PATHS_LIST}" ]] || {
  echo "indexcost: no ${PATHS_LIST} — run \`gist index\` first" >&2
  exit 1
}
have cindex || {
  echo "indexcost: cindex not on PATH (go install github.com/google/codesearch/cmd/cindex@latest)" >&2
  exit 1
}
[[ -x "${GIST_BIN}" ]] || {
  echo "indexcost: no ${GIST_BIN} — run \`make install-gist\` first" >&2
  exit 1
}

now() { python3 -c 'import time;print(time.time())'; }
size_of() { stat -f%z "$1" 2> /dev/null || stat -c%s "$1" 2> /dev/null || echo 0; }

# Peak RSS in BYTES for a command, or -1 where the kernel won't say. `/usr/bin/time`
# reports bytes on BSD/macOS and KiB on GNU; both shapes are normalized here.
RSS_LOG="$(mktemp)"
trap 'rm -f "${RSS_LOG}" "${RSS_PATHS:-}"' EXIT
peak_rss() {
  /usr/bin/time -l "$@" > /dev/null 2> "${RSS_LOG}" || true
  awk '/maximum resident set size/ {print $1; found=1; exit}
       /Maximum resident set size/ {sub(/.*: /, ""); print $1 * 1024; found=1; exit}
       END {if (!found) print -1}' "${RSS_LOG}"
}

# The corpus both indexes cover, straight off the shared file list.
read -r corpus_files corpus_bytes < <(cd "${CORPUS}" && python3 -c '
import os, sys
paths = [p for p in open(sys.argv[1], "rb").read().split(b"\0") if p]
print(len(paths), sum(os.path.getsize(p) for p in paths if os.path.exists(p)))
' "${PATHS_LIST}")

echo "indexcost: ${corpus_files} files · ${corpus_bytes} B — one file list, two indexes"

# ── csearch (cindex) ─────────────────────────────────────────────────────────
rm -f "${CSEARCH_IDX}"
t0="$(now)"
(cd "${CORPUS}" && xargs -0 -n 400 env CSEARCHINDEX="${CSEARCH_IDX}" cindex < "${PATHS_LIST}" > /dev/null 2>&1)
t1="$(now)"
cs_ms="$(python3 -c "print('%.1f'%((${t1}-${t0})*1000))")"
cs_bytes="$(size_of "${CSEARCH_IDX}")"
# One representative shard re-run under the RSS meter: `cindex` is invoked in
# 400-path batches (that is csearch's own driver shape, kept from `_compete.sh`),
# so the peak of a single batch IS the peak of the build — the run never holds
# more than one batch at a time. Reported as such, not as a whole-corpus figure.
RSS_PATHS="$(mktemp)"
python3 -c '
import sys
paths = [p for p in open(sys.argv[1], "rb").read().split(b"\0") if p][:400]
open(sys.argv[2], "wb").write(b"\0".join(paths))
' "${PATHS_LIST}" "${RSS_PATHS}"
cs_rss="$(cd "${CORPUS}" && peak_rss env CSEARCHINDEX="${COMPETE_DIR}/csearch.rss.idx" xargs -0 -a "${RSS_PATHS}" cindex)"
rm -f "${COMPETE_DIR}/csearch.rss.idx"

# ── gist ─────────────────────────────────────────────────────────────────────
t0="$(now)"
(cd "${CORPUS}" && "${GIST_BIN}" index > /dev/null 2>&1)
t1="$(now)"
g_ms="$(python3 -c "print('%.1f'%((${t1}-${t0})*1000))")"
g_bytes="$(size_of "${OUT}/index.gist")"
g_rss="$(cd "${CORPUS}" && peak_rss "${GIST_BIN}" index)"

{
  printf '# corpus_files\tcorpus_bytes\n# %s\t%s\n' "${corpus_files}" "${corpus_bytes}"
  printf 'tool\tindex_bytes\tbuild_ms\tpeak_rss_bytes\n'
  printf 'gist\t%s\t%s\t%s\n' "${g_bytes}" "${g_ms}" "${g_rss}"
  printf 'csearch\t%s\t%s\t%s\n' "${cs_bytes}" "${cs_ms}" "${cs_rss}"
} > "${OUT_TSV}"

printf '  gist    %10s B index · %8s ms build · %10s B peak RSS\n' "${g_bytes}" "${g_ms}" "${g_rss}"
printf '  csearch %10s B index · %8s ms build · %10s B peak RSS\n' "${cs_bytes}" "${cs_ms}" "${cs_rss}"
echo "wrote ${OUT_TSV}"
