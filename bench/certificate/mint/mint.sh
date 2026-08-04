#!/usr/bin/env bash
# mint.sh — irregex's Dominance-and-Fit Certificate: Layers B, B′, C, D, E, J, L.
#
# THIS PACKAGE CERTIFIES WHAT IT BUILDS. irregex is the engine and the `libirgx`
# C-ABI floor — a library, no CLI — so what it can certify is not "faster than a
# rival product" but the thing no product downstream can even ask: **how close
# the engine runs to the physical and information-theoretic limits of the machine
# it is on.** Every layer below is a stated bound with a measured distance to it,
# and the honest answer is sometimes "there is no headroom left".
#
#   B    port-optimality, static — llvm-mca's issue bound for the two hot loops
#        on two cores LLVM models precisely (this machine's Apple core it does not)
#   B′   the same bound MEASURED, from this machine's own counters (needs sudo)
#   C    roofline — the memory ceiling and the fraction of it the scan reaches
#   D    the information-theoretic floor a trigram directory can reach, audited
#        fail-closed against the bytes actually touched
#   E    crest sieve — the one place the index math is new rather than borrowed,
#        fail-closed on `matched ⇒ ¬pruned` over the whole corpus
#   J    substring/positional index tiers at scale, including the tier DECLINED
#   L    index quality head-to-head against csearch, on candidates AND on cost
#
# Layer A and the CLI surface (H, I) are minted by `gist`; retrieval and
# multi-pattern (F, G, K) by `relate`. This mint neither drives nor waits on
# them: each package publishes its own bundle, over its own corpus, with its own
# ledger. The roster this script must satisfy is `guard/profile.py`, and the
# completeness gate at the end reads it rather than a second list kept by hand.
#
# Usage:  bash bench/certificate/mint/mint.sh
#         CERT_SUDO=1 bash bench/certificate/mint/mint.sh    (PMU for B′)
#         CERT_PUBLISH_DIR=bench/certificate/artifact \
#           bash bench/certificate/mint/mint.sh              (mint + publish)
#
# Env:  CERT_CORPUS_ID    which declared corpus this measures; must name a row in
#                         `bench/certificate/corpus.toml`, whose `fetch` recipe
#                         the floor runs if that tree isn't already here
#                         (default: ecosystem-v1)
#       GIST_CORPUS_ROOT  measure a tree already on disk instead of fetching one;
#                         its roots must match what the charter declares
#       CERT_SUDO         1 prompt / 0 skip / unset auto-detect passwordless
#       CERT_ALLOW_DIRTY  1 to mint from an uncommitted tree (local refresh)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Which declared corpus this bundle measures. The floor reads it, asks the
# charter for that corpus's roots and fetch recipe, materializes it if its roots
# are not already here, and refuses the run if the tree it would walk is not the
# one the bundle would claim.
#
# `ecosystem-v1` rather than the self corpus because of Layer L, which compares
# two index PLANNERS by the candidate bytes each admits: a probe class matching
# nothing (or everything) admits the identical set under both, so it feeds noise
# to a fail-closed verdict. `rungs/sieve/slate.py --audit` measures that with a
# foreign regex engine — on the self corpus all 20 classes discriminate but the
# tree is monoglot Zig; on gist's synthetic Go corpus 16 of 20 are degenerate.
# Only the ecosystem tree is both polyglot and fully discriminating.
export CERT_CORPUS_ID="${CERT_CORPUS_ID:-ecosystem-v1}"

# The vendored measurement floor: roots, corpus scope, and the rival index
# construction Layers J and L race against. Identical bytes in all four
# packages, so a candidate-byte number here and one in `gist` are comparable.
# shellcheck source=../../apparatus/field.sh
source "${HERE}/../../apparatus/field.sh"

RUNS="${RUNS:-20}"
WARMUP="${WARMUP:-3}"
CERT="${OUT}/CERTIFICATE.md"
WORK="${COMPETE_DIR}/certify"
ART="${KERNEL}/bench/rungs/sliver/artifact" # the at-scale race's committed evidence
mkdir -p "${OUT}" "${WORK}"

# Resolved once, not per splice: the machine and toolchain a mint reports must be
# the same two strings in every layer of one bundle.
ARCH="$(uname -m)"
ZIG_VERSION="$(zig version)"

die() {
  echo "certificate aborted: $*" >&2
  exit 1
}

# Run a corpus-walking lane. Its CWD is the CORPUS, not the checkout: every one
# of these resolves its roots relative to where it is standing, so a lane run
# from the package would walk `${KERNEL}/irregex` — which does not exist — and
# report an empty corpus rather than the tree the bundle names. The binary is
# addressed absolutely for the same reason.
lane() {
  local exe="${KERNEL}/zig-out/bin/$1"
  [[ -x "${exe}" ]] || die "no ${exe} — the lane build did not produce it"
  (cd "${CORPUS}" && "${exe}") || die "$1 failed"
}

# Refuse to mint a certificate whose machine.git_commit could not equal a clean
# HEAD — unless CERT_ALLOW_DIRTY=1 (local refresh / coworking trees).
git -C "${KERNEL}" rev-parse --verify HEAD > /dev/null 2>&1 || die "cannot resolve git HEAD"
dirty="$(git -C "${KERNEL}" status --porcelain 2> /dev/null || true)"
if [[ -n "${dirty}" && "${CERT_ALLOW_DIRTY:-0}" != "1" ]]; then
  echo "certificate aborted: worktree is dirty — commit or isolate changes before certifying" >&2
  echo "(local refresh: CERT_ALLOW_DIRTY=1 bash bench/certificate/mint/mint.sh)" >&2
  git -C "${KERNEL}" status --porcelain >&2
  exit 1
fi

# Seed the document. `gist` gets its preamble from `gist-bench certify`, which
# rewrites the whole file; this package has no such writer, and every reporter
# below SPLICES — it replaces its own section and appends when absent. Without a
# seed the first splice would be writing the header of a file that does not
# exist. Rewritten every mint on purpose: a certificate is the bytes of one run.
cat > "${CERT}" << EOF
# irregex — Dominance-and-Fit Certificate

The engine's distance from the limits of the machine it runs on. Each layer
states a bound the hardware or information theory imposes, then measures how
close this build gets to it — so a layer reporting **no remaining headroom** is
as much a result as one reporting a win.

Minted by \`bench/certificate/mint/mint.sh\`. Every number below is spliced by a
reporter that reads a committed artifact in this bundle; nothing here is typed
by hand. The machine, the tool identities, and the corpus that produced it are
\`machine.json\`, \`tool-versions.txt\`, and \`corpus-manifest.tsv\` beside this file.

Layer A (dominance over the field) and the CLI surface belong to \`gist\`;
retrieval and multi-pattern to \`relate\`. A package certifies what it builds.
EOF

# Exactly the five lane binaries this certificate splices, via the install-only
# `build-<lane>` steps — not `zig build lab`, which also builds the production
# rungs (parabix, sweep, ladder-price, …) that no layer here reads. A rung
# mid-refactor would otherwise abort a mint it has nothing to do with.
echo "building the lane binaries this certificate needs…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast \
  build-roofline build-portbound build-lowerbound build-scale build-indexq) \
  || die "could not build the certificate lanes"

# ── Layer B — the static bound ───────────────────────────────────────────────
# Degrades rather than fails: without llvm-mca there is no static model to ask,
# and a certificate that lied about having one would be worse than a short one.
echo "certifying port-optimality (Layer B, static)…"
bash "${KERNEL}/bench/bounds/port/mca.sh" || die "Layer B (mca) failed"

# ── Layer B′ — the same bound, measured here ─────────────────────────────────
# Counters need root on macOS. Without them the run still emits portbound.json
# with its cycles marked unmeasured, and Layer B's reporter renders it as such.
echo "measuring the port bound on this machine (Layer B′)…"
PORTBOUND="${KERNEL}/zig-out/bin/gist-portbound"
[[ -x "${PORTBOUND}" ]] || die "no ${PORTBOUND} after the build-portbound step"
case "${CERT_SUDO:-auto}" in
  0) echo "  CERT_SUDO=0 — B′ stays wall-clock (cycles labeled NOT measured)" ;;
  1) (cd "${KERNEL}" && sudo "${PORTBOUND}") || die "sudo gist-portbound failed" ;;
  *)
    if sudo -n true 2> /dev/null; then
      (cd "${KERNEL}" && sudo -n "${PORTBOUND}") || die "sudo -n gist-portbound failed"
    else
      echo "  no passwordless sudo — B′ stays wall-clock; CERT_SUDO=1 to prompt once"
      (cd "${KERNEL}" && "${PORTBOUND}") || die "gist-portbound failed"
    fi
    ;;
esac
# Re-splice B now that portbound.json exists: B's reporter renders B′ as a
# subsection of B, discovering the measured JSON beside its own.
bash "${KERNEL}/bench/bounds/port/mca.sh" || die "Layer B re-splice failed"

# ── Layer C — the roofline ───────────────────────────────────────────────────
echo "certifying the roofline (Layer C)…"
lane gist-roofline
python3 "${KERNEL}/bench/bounds/roofline/report.py" \
  --out-dir "${OUT}" --certificate "${CERT}" || die "Layer C splice failed"

# ── Layer D — the algorithmic floor ──────────────────────────────────────────
# Fail-closed by construction: the audit exits non-zero if the engine touched
# fewer bytes than the information-theoretic floor allows, which would mean the
# floor is wrong or the measurement is.
echo "auditing the algorithmic lower bound (Layer D)…"
lane gist-lowerbound
python3 "${KERNEL}/bench/bounds/lowerbound/report.py" \
  --csv "${OUT}/lowerbound.csv" --certificate "${CERT}" || die "Layer D splice failed"

# ── Layer E — the crest sieve ────────────────────────────────────────────────
# A spliced Layer E IS the soundness receipt: the proof aborts on a single false
# negative, and this script does not splice what did not pass.
echo "certifying the crest sieve (Layer E, fail-closed)…"
CERT_OUT="${OUT}" bash "${HERE}/crest.sh" || die "Layer E (crest) failed"

# ── the shared corpus both index layers race over ────────────────────────────
# J and L compare index tiers against real indexed rivals, so they need the
# rivals' indexes over byte-identical files. The floor builds gist's index first
# because `paths.list` — the doc→path table its indexer persists — is what
# csearch is then pointed at.
echo "building the shipped index + the rival indexes…"
compete_build_gist_index || die "could not build gist's index over the corpus"
compete_build_csearch
compete_build_zoekt

# ── Layer J — index tiers at scale ───────────────────────────────────────────
# The at-scale race needs a multi-GB corpus and hours; its evidence is committed
# under `bench/rungs/sliver/artifact/` and re-measured deliberately, not on every
# mint. What runs here is the tier audit against THIS build, which is the part
# that can silently regress. Each optional TSV is passed only if it exists, so a
# fresh checkout mints a narrower Layer J rather than no Layer J.
echo "certifying index tiers at scale (Layer J)…"
lane gist-scale
scale_args=(--certificate "${CERT}" --tsv "${OUT}/scale_tiers.tsv"
  --sidecar "${OUT}/scale.csv" --machine "${ARCH}" --zig "${ZIG_VERSION}")
for pair in race:scale_race build:scale_build resident:scale_resident \
  pareto:positional_pareto elision:scale_elision walkcost:scale_walkcost; do
  [[ -f "${ART}/${pair#*:}.tsv" ]] && scale_args+=("--${pair%%:*}" "${ART}/${pair#*:}.tsv")
done
python3 "${HERE}/../report/scale.py" "${scale_args[@]}" || die "Layer J splice failed"

# ── Layer L — index quality vs csearch ───────────────────────────────────────
# Two halves, both fail-closed in the reporter: candidates admitted (the plan is
# lifted from csearch's OWN formula, so the comparison is against what csearch
# would really do) and what each index charges for them.
echo "certifying index quality vs csearch (Layer L)…"
python3 "${KERNEL}/bench/rungs/sieve/csearch_plan.py" \
  --probes "${KERNEL}/bench/apparatus/harness/probes.zig" \
  --probes "${KERNEL}/bench/rungs/sieve/stress.zig" \
  --index "${CSEARCH_IDX}" --out "${OUT}/indexq_csearch.plan" || die "csearch plan lift failed"
lane gist-indexq
bash "${KERNEL}/bench/rungs/sieve/indexcost.sh" || die "Layer L cost arm failed"
python3 "${HERE}/../report/indexq.py" \
  --certificate "${CERT}" --tsv "${OUT}/indexq.tsv" \
  --cost-tsv "${OUT}/indexcost.tsv" \
  --machine "${ARCH}" --zig "${ZIG_VERSION}" || die "Layer L splice failed"

# ── provenance — the three artifacts that make a number re-derivable ─────────
# --root is the CORPUS (paths.list is relative to it), --source-root the checkout
# whose HEAD built the binaries. They differ whenever the mint runs against a
# corpus snapshot, and hashing the manifest against the wrong one silently
# produces rows for files nothing measured.
echo "emitting reproducibility metadata…"
pins=()
for t in zig hyperfine csearch zoekt llvm-mca; do
  if tool_bin="$(command -v "${t}" 2> /dev/null)"; then pins+=(--tool "${t}=${tool_bin}"); fi
done
[[ "${CERT_ALLOW_DIRTY:-0}" = "1" ]] && pins+=(--allow-dirty)
python3 "${KERNEL}/bench/apparatus/provenance.py" \
  --out "${OUT}" --root "${CORPUS}" --source-root "${KERNEL}" \
  --corpus-id "${CERT_CORPUS_ID}" \
  --roots "${ROOTS[*]}" --paths-list "${PATHS_LIST}" \
  --runs "${RUNS}" --warmup "${WARMUP}" \
  "${pins[@]}" || die "provenance emit failed"

# Structural completeness only — a bundle is judged on its bytes, never on the
# tree that produced it.
python3 "${HERE}/../guard/artifacts.py" --artifacts-dir "${OUT}" --artifacts || exit 1

# Publish a committed snapshot when asked (CERT_PUBLISH_DIR is package-relative).
if [[ -n "${CERT_PUBLISH_DIR:-}" ]]; then
  pub="${KERNEL}/${CERT_PUBLISH_DIR}"
  mkdir -p "${pub}"
  cp -f "${CERT}" "${OUT}/machine.json" "${OUT}/tool-versions.txt" \
    "${OUT}/corpus-manifest.tsv" "${pub}/"
  # Driven from `profile.py`, so a new layer publishes its receipt without a
  # second list to keep in step.
  sidecar_list="$(python3 "${HERE}/../guard/profile.py" sidecars)" || exit 1
  mapfile -t sidecars <<< "${sidecar_list}"
  for side in portbound.json indexcost.tsv "${sidecars[@]}"; do
    [[ -f "${OUT}/${side}" ]] && cp -f "${OUT}/${side}" "${pub}/"
  done
  # --public-safe is the difference between a mint and a PUBLISH: entering git
  # means a stranger must be able to fetch this corpus and re-derive the number,
  # and it means no private path rides along in a manifest row.
  python3 "${HERE}/../guard/artifacts.py" --artifacts-dir "${pub}" --artifacts --public-safe \
    || exit 1
  echo "published reproducible certificate → ${pub}"
  python3 "${HERE}/../ledger/ledger.py" record --bundle "${pub}" || exit 1
fi
