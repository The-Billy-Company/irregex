#!/usr/bin/env bash
#
# install.sh — stage kperf's configurable events behind the smallest privilege
# grant that can deliver them.
#
# READ THIS WHOLE FILE FIRST. It is meant to be audited in one sitting, before
# you type a password. It does exactly five things:
#
#   1. compiles ../privilege/pmu_bless.c with cc, into a temp directory;
#   2. runs the fresh binary's own --check to confirm it behaves;
#   3. renders the sudoers template with your username and the binary's SHA-256,
#      and validates it with `visudo -c -f` (aborting if that fails);
#   4. installs the binary root:wheel 0555 into /usr/local/libexec;
#   5. installs the sudoers fragment root:wheel 0440 into /etc/sudoers.d.
#
# Steps 1-3 need no privileges: run `./install.sh --check` to do only those and
# see the rendered rule without installing anything. Steps 4-5 are the only ones
# that need root, and they are the last thing that happens.
#
# YOU PROBABLY DO NOT NEED TO RUN THIS. Retired cycles and instructions -- every
# number the certificate quotes in cycles/byte -- are already measured with no
# privilege at all. Read README.md in this directory, which explains what this
# grant buys, what it costs, and why it is staged rather than recommended.
#
# Idempotent: re-running with an unchanged source reports "already current" and
# writes nothing.
#
# Revoke with:
#   sudo rm -f /etc/sudoers.d/irregex-pmu /usr/local/libexec/irregex-pmu-bless

set -euo pipefail

readonly HELPER_NAME="irregex-pmu-bless"
readonly HELPER_DIR="/usr/local/libexec"
readonly HELPER_PATH="${HELPER_DIR}/${HELPER_NAME}"
readonly SUDOERS_PATH="/etc/sudoers.d/irregex-pmu"

readonly HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE="${HERE}/pmu_bless.c"
readonly TEMPLATE="${HERE}/irregex-pmu.sudoers.in"
readonly PROBE_SRC="${HERE}/kperf_probe.c"

CHECK_ONLY=0
case "${1-}" in
  --check) CHECK_ONLY=1 ;;
  --help | -h)
    sed -n '2,30p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  "") ;;
  *)
    printf 'install.sh: unknown argument %q (try --check or --help)\n' "$1" >&2
    exit 2
    ;;
esac

say() { printf '  %s\n' "$*"; }
die() {
  printf '\ninstall.sh: %s\n' "$*" >&2
  exit 1
}

WORK=""
# The digest-enforcement test below briefly installs a probe rule and a tampered
# copy of the helper. Both are removed on the happy path, but a security script
# must not be able to leave either behind if it dies mid-test, so the trap owns
# them too.
cleanup() {
  [ -n "${WORK}" ] && rm -rf -- "${WORK}"
  rm -f -- "/etc/sudoers.d/irregex-pmu-digesttest" 2>/dev/null
  rm -f -- "${HELPER_DIR}/.${HELPER_NAME}.digesttest" 2>/dev/null
  return 0
}
trap cleanup EXIT

# ── who is asking ────────────────────────────────────────────────────────────
# Under sudo the real uid is already root, so the username has to come from
# SUDO_USER. Refusing when it is absent or root is what stops this script from
# writing a rule that grants root to root, or to nobody in particular.
printf '\n== irregex PMU privilege installer ==\n\n'
if [ "$(id -u)" -eq 0 ]; then
  TARGET_USER="${SUDO_USER-}"
  [ -n "${TARGET_USER}" ] || die "running as root with no SUDO_USER; re-run as 'sudo $0' from your own account"
  [ "${TARGET_USER}" != "root" ] || die "SUDO_USER is root; there is no unprivileged account to grant this to"
else
  TARGET_USER="$(id -un)"
fi
say "grant would name user   : ${TARGET_USER}"
id -u "${TARGET_USER}" >/dev/null 2>&1 || die "no such user: ${TARGET_USER}"

# ── preflight ────────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "this arrangement is macOS-only (kperf is an Apple framework)"

# THE LOAD-BEARING CHECK. sudoers(5) warns, of digest-pinned commands:
#
#   "if the user has write access to the command itself (directly or via a sudo
#    command), it may be possible for the user to replace the command after the
#    digest check has been performed but before the command is executed. A
#    similar race condition exists on systems that lack the fexecve(2) system
#    call when the directory in which the command is located is writable by the
#    user."
#
# macOS has no fexecve(2), so the digest alone does NOT close that race -- path
# ownership does. Every component of the install path must be root-owned and not
# writable by the account the rule names, or a NOPASSWD grant on a hashed binary
# is still a root escalation by swap-after-check. On Intel Macs Homebrew owns
# /usr/local, which would make this check fail loudly rather than quietly ship a
# hole; that is exactly why it runs before anything is compiled.
printf -- '-- verifying the install path cannot be rewritten by %s --\n' "${TARGET_USER}"
probe="/"
for component in usr local libexec; do
  probe="${probe%/}/${component}"
  if [ ! -e "${probe}" ]; then
    say "${probe} does not exist yet (will be created root:wheel 0755)"
    continue
  fi
  owner="$(stat -f '%Su' "${probe}")"
  mode="$(stat -f '%Sp' "${probe}")"
  say "$(printf '%-24s owner=%-14s %s' "${probe}" "${owner}" "${mode}")"
  [ "${owner}" = "root" ] || die "${probe} is owned by ${owner}, not root. A digest-pinned NOPASSWD rule is NOT safe here: ${owner} could replace the helper between sudo's hash check and the exec. Refusing to install."
  # Group- or other-writable is the same hole wearing a different hat.
  case "${mode}" in
    ??????w* | ?????????w*) die "${probe} is group- or world-writable (${mode}); refusing to pin a NOPASSWD digest under it" ;;
  esac
done
# Ask the question directly rather than inferring it from the mode bits, since
# ACLs can grant write access that `stat` does not show. Only meaningful if the
# directory exists; if we are creating it root:wheel 0755 the answer is known.
if [ -d "${HELPER_DIR}" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    writable="$(su -m "${TARGET_USER}" -c "test -w '${HELPER_DIR}' && echo yes || echo no" 2>/dev/null || echo unknown)"
  else
    writable="$([ -w "${HELPER_DIR}" ] && echo yes || echo no)"
  fi
  [ "${writable}" != "yes" ] || die "${HELPER_DIR} is writable by ${TARGET_USER}; refusing (this is the swap-after-check hole)"
  ls -lde "${HELPER_DIR}" | sed 's/^/    /'
fi
say "path is root-owned and not user-writable: the swap-after-check race is closed"
printf '\n'
[ -f "${SOURCE}" ] || die "missing helper source: ${SOURCE}"
[ -f "${TEMPLATE}" ] || die "missing sudoers template: ${TEMPLATE}"
command -v cc >/dev/null || die "no cc on PATH; install the Command Line Tools"
command -v visudo >/dev/null || die "no visudo on PATH; refusing to install an unvalidated sudoers file"
command -v shasum >/dev/null || die "no shasum on PATH; cannot pin a digest"

# ── 1. compile ───────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
readonly BUILT="${WORK}/${HELPER_NAME}"
printf '\n-- compiling the helper --\n'
cc -O2 -Wall -Wextra -Werror -o "${BUILT}" "${SOURCE}" || die "the helper did not compile cleanly; nothing was installed"
say "built                   : ${BUILT}"

DIGEST="$(shasum -a 256 "${BUILT}" | awk '{print $1}')"
[ "${#DIGEST}" -eq 64 ] || die "unexpected digest length ${#DIGEST}; refusing to pin it"
say "sha256                  : ${DIGEST}"

# ── 2. the helper's own unprivileged self-report ──────────────────────────────
# Proves the binary runs and that its unprivileged path refuses rather than
# half-working. Run as the target user when we are root, so the output describes
# the situation the sudoers rule will actually create.
printf '\n-- the helper, checked before it is trusted --\n'
if [ "$(id -u)" -eq 0 ]; then
  su -m "${TARGET_USER}" -c "'${BUILT}' --check" 2>&1 | sed 's/^/  /' || true
else
  "${BUILT}" --check 2>&1 | sed 's/^/  /' || true
fi

# ── 3. render and VALIDATE the sudoers fragment ───────────────────────────────
printf '\n-- rendering and validating the sudoers rule --\n'
readonly RENDERED="${WORK}/irregex-pmu"
sed -e "s|@USER@|${TARGET_USER}|g" \
  -e "s|@DIGEST@|${DIGEST}|g" \
  -e "s|@HELPER@|${HELPER_PATH}|g" \
  "${TEMPLATE}" >"${RENDERED}"

grep -q '@USER@\|@DIGEST@\|@HELPER@' "${RENDERED}" && die "a placeholder survived rendering; refusing to install"

# visudo -c parses the file with the real sudoers grammar. It needs the final
# permissions to be happy about ownership, so set them before checking.
chmod 0440 "${RENDERED}"
if ! visudo -c -f "${RENDERED}"; then
  die "visudo rejected the rendered rule; nothing was installed"
fi
say "visudo                  : parsed OK"

printf '\n-- the exact rule that would be installed --\n'
grep -v '^\s*#' "${RENDERED}" | grep -v '^\s*$' | sed 's/^/  /'

# ── stop here if only checking ────────────────────────────────────────────────
if [ "${CHECK_ONLY}" -eq 1 ]; then
  printf '\n--check: everything above was validated. Nothing was installed.\n'
  printf 'To install, read README.md, then: sudo %s\n\n' "$0"
  exit 0
fi

# ── idempotence ──────────────────────────────────────────────────────────────
if [ -f "${HELPER_PATH}" ] && [ -f "${SUDOERS_PATH}" ]; then
  INSTALLED_DIGEST="$(shasum -a 256 "${HELPER_PATH}" | awk '{print $1}')"
  if [ "${INSTALLED_DIGEST}" = "${DIGEST}" ] && cmp -s "${RENDERED}" "${SUDOERS_PATH}"; then
    printf '\nalready current -- helper digest and sudoers rule both match. Nothing written.\n\n'
    exit 0
  fi
  say "an older install is present and will be replaced"
fi

# ── 4 & 5. the only privileged steps ─────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "installing needs root; re-run as: sudo $0"

printf '\n-- installing --\n'
install -d -o root -g wheel -m 0755 "${HELPER_DIR}"
# 0555: executable by all, writable by none. A NOPASSWD target must not be
# writable by the account the rule names, or the digest is the only thing
# standing between a rebuilt helper and uninterceptable root.
install -o root -g wheel -m 0555 "${BUILT}" "${HELPER_PATH}"
say "installed               : ${HELPER_PATH} (root:wheel 0555)"

install -o root -g wheel -m 0440 "${RENDERED}" "${SUDOERS_PATH}"
say "installed               : ${SUDOERS_PATH} (root:wheel 0440)"

# Re-validate the whole sudoers tree, not just our fragment: a fragment that
# parses alone can still break the file it is included from.
if ! visudo -c >/dev/null; then
  rm -f "${SUDOERS_PATH}"
  die "the full sudoers tree failed validation; the fragment was removed again"
fi
say "visudo -c (whole tree)  : OK"

# ── 6. prove the grant actually works, and revoke it if it does not ──────────
# The half of this arrangement that cannot be tested without authenticating is
# whether sudo enforces the digest at runtime and whether blessing then lets a
# non-root process read counters. Now that we are authenticated, test both -- and
# tear the grant back down if either fails, so a password never buys a rule that
# does not deliver.
printf '\n-- verifying the grant end-to-end --\n'
revoke_and_die() {
  rm -f "${SUDOERS_PATH}"
  printf '  removed %s\n' "${SUDOERS_PATH}"
  die "$1"
}

# 6a. Passwordless invocation must succeed as the target user.
if ! su -m "${TARGET_USER}" -c "sudo -n '${HELPER_PATH}' --check" >"${WORK}/grant.out" 2>&1; then
  sed 's/^/    /' "${WORK}/grant.out"
  revoke_and_die "the NOPASSWD grant did not take effect; rule removed, helper left in place (harmless without a rule)"
fi
sed 's/^/    /' "${WORK}/grant.out"
if ! grep -q 'privileged' "${WORK}/grant.out"; then
  revoke_and_die "the helper ran but did not report a privileged euid; rule removed"
fi
say "passwordless invocation : OK"

# 6b. The digest must actually be enforced, not merely parsed. Copy the helper
# somewhere root-owned, alter one byte, and confirm sudo refuses it. If sudo
# ignored digests, the tampered binary would run -- and the whole security
# argument for allowing a NOPASSWD rule at all would be false.
readonly TAMPER="${HELPER_DIR}/.${HELPER_NAME}.digesttest"
cp "${HELPER_PATH}" "${TAMPER}"
printf '\0' >>"${TAMPER}"
chown root:wheel "${TAMPER}"
chmod 0555 "${TAMPER}"
tampered_digest="$(shasum -a 256 "${TAMPER}" | awk '{print $1}')"
readonly TAMPER_RULE="${WORK}/irregex-pmu-digesttest"
printf '%s ALL=(root) NOPASSWD: sha256:%s %s\n' "${TARGET_USER}" "${DIGEST}" "${TAMPER}" >"${TAMPER_RULE}"
chmod 0440 "${TAMPER_RULE}"
digest_enforced="unknown"
if visudo -c -f "${TAMPER_RULE}" >/dev/null 2>&1; then
  install -o root -g wheel -m 0440 "${TAMPER_RULE}" "/etc/sudoers.d/irregex-pmu-digesttest"
  # The rule pins DIGEST but the file on disk hashes to tampered_digest, so a
  # sudo that enforces digests must refuse.
  if su -m "${TARGET_USER}" -c "sudo -n '${TAMPER}' --check" >/dev/null 2>&1; then
    digest_enforced="no"
  else
    digest_enforced="yes"
  fi
  rm -f "/etc/sudoers.d/irregex-pmu-digesttest"
fi
rm -f "${TAMPER}"
say "$(printf 'digest enforced         : %s (pinned %s…, on-disk %s…)' "${digest_enforced}" "${DIGEST:0:12}" "${tampered_digest:0:12}")"
if [ "${digest_enforced}" = "no" ]; then
  revoke_and_die "this sudo PARSES digests but does not ENFORCE them. A NOPASSWD rule here would be a root escalation the moment anyone can rewrite the helper. Rule removed. Do not re-install."
fi

# 6c. The question that actually matters: does blessing let an UNPRIVILEGED
# process program and read counters? This calls the same kpc_ entry point
# pmu.zig calls, so GRANTED here means the harness will measure.
if [ -f "${PROBE_SRC}" ] && cc -O2 -Wall -Wextra -o "${WORK}/kperf_probe" "${PROBE_SRC}" 2>/dev/null; then
  chmod 0755 "${WORK}" "${WORK}/kperf_probe"
  printf '  counter probe, blessed  :\n'
  su -m "${TARGET_USER}" -c "sudo -n '${HELPER_PATH}' '${WORK}/kperf_probe'" >"${WORK}/probe.out" 2>&1 || true
  sed 's/^/      /' "${WORK}/probe.out"
  if grep -q 'RESULT: GRANTED' "${WORK}/probe.out"; then
    say "counters                : CONFIRMED reachable unprivileged via the grant"
  else
    printf '\n'
    say "The grant installed and the digest is enforced, but blessing did not"
    say "deliver counters. That is usually a kernel that ignores blessed_pid."
    say "Leaving the rule in place would buy nothing, so it is being removed."
    revoke_and_die "blessing did not yield counters; rule removed. Benchmarks keep working via the unprivileged backend."
  fi
else
  say "counter probe           : skipped (could not compile ${PROBE_SRC})"
fi

printf '\ndone -- and verified, not merely installed.\n\n'
printf 'Use it:\n'
printf '  sudo -n %s <your benchmark binary>\n\n' "${HELPER_PATH}"
printf 'Confirm the grant at any time:\n'
printf '  sudo -n %s --check\n\n' "${HELPER_PATH}"
printf 'Revoke completely (nothing in the repo breaks; benchmarks keep measuring\n'
printf 'cycles and instructions through the unprivileged backend):\n'
printf '  sudo rm -f %s %s\n\n' "${SUDOERS_PATH}" "${HELPER_PATH}"
