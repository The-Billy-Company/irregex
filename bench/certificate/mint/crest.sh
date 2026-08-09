#!/usr/bin/env bash
# certify_crest.sh — Layer E of the Dominance-and-Fit Certificate: the crest sieve.
#
# The one place gist's index math is new rather than borrowed. The trigram index
# (and every trigram-family peer) prunes 0% on literal-free class repetitions —
# `[0-9a-f]{12}`, `[0-9]{6}` — the Layer A `regex-classcount` hole (cand%=100%).
# The crest sieve closes it with a sound forced-class-run necessary condition
# (`src/kernel/math/crest.zig`, proof in `research/crest/PROOF.md`).
#
# `zig build crest` links the REAL engine, builds the production crest sidecar,
# walks the real corpus, and is FAIL-CLOSED: `matched ⇒ ¬pruned` against the
# production matcher over the whole corpus + randomized adversarial sweeps. A
# single false negative exits non-zero and this script aborts WITHOUT splicing —
# so a spliced Layer E is itself the soundness receipt. No PMU/sudo needed
# (wall-clock full-scan vs sieve-survivors, same matcher both sides).
#
# Usage (from repo root or anywhere):
#   bash bench/certificate/mint/crest.sh
# Env:
#   CERT_OUT=DIR   certificate dir (default: the artifact home, <corpus>/.gist)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The vendored resolver, not a hand-counted climb: KERNEL is this checkout (what
# builds and what git records), CORPUS is the tree measured — which is the same
# here unless GIST_CORPUS_ROOT points the mint at a snapshot.
# shellcheck source=../../apparatus/roots.sh
source "${HERE}/../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1
OUT="${CERT_OUT:-${GIST_VERIFY}}"
CERT="${OUT}/CERTIFICATE.md"
CREST_CSV="${OUT}/crest.csv"
# The binary is run with CORPUS as its CWD (see below), and bench.zig's evidence
# writer resolves `.local/crest-evidence/` relative to wherever it stands — so
# the raw file lands under CORPUS, not KERNEL, whenever the two differ
# (GIST_CORPUS_ROOT set). Pointing this at KERNEL silently copied a stale
# self-corpus run's leftovers into the certificate instead of failing loud.
CREST_RAW="${CORPUS}/.local/crest-evidence/crest.csv"

die() {
  echo "certify_crest: $*" >&2
  exit 1
}
note() { echo "certify_crest: $*"; }

[[ -s "${CERT}" ]] || die "missing ${CERT} — run Layer A first (\`zig build certify\` in the gist package, which mints it)"

# The standalone proof owns its complete raw evidence package under
# .local/crest-evidence; copy the aggregate into the certificate bundle.
note "building + running the crest production proof (fail-closed)…"
# Built and RUN as two steps, because the two have different working
# directories. `zig build crest` would run the proof from the checkout, and the
# proof resolves its corpus roots relative to where it stands — so against a
# materialized corpus it walked an empty tree and (before the guard in
# `bench.zig`) died on a SEGV that read like a soundness failure. Build here,
# run from CORPUS, exactly as the other lanes do.
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast build-crest) \
  || die "could not build the crest proof"
(cd "${CORPUS}" && "${KERNEL}/zig-out/bin/crest") \
  || die "crest proof failed — a soundness violation aborts the certificate; do NOT weaken the sieve, fix the calculus"
[[ -s "${CREST_RAW}" ]] || die "crest proof did not emit ${CREST_RAW}"
cp -f "${CREST_RAW}" "${CREST_CSV}"

# Measured-on-this-machine provenance (same brand string the other layers use).
if machine="$(sysctl -n machdep.cpu.brand_string 2> /dev/null)"; then :; else machine="$(uname -m)"; fi
zig="$(cd "${KERNEL}" && zig version)"

python3 "${HERE}/../report/crest.py" \
  --certificate "${CERT}" \
  --csv "${CREST_CSV}" \
  --machine "${machine}" \
  --zig "${zig}" \
  || die "Layer E splice failed"

grep -qF "## Layer E — crest sieve" "${CERT}" || die "Layer E section missing after splice"
note "Layer E (crest sieve) spliced into ${CERT}"
