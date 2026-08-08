#!/usr/bin/env bash
#
# fable-repo-aptcheck.sh
#
# Verify a fable-repo snapshot with the real apt implementation:
#   - apt-get update against the flat repo (signature enforced via signed-by)
#   - apt-cache policy resolves every expected package to a candidate version
#
# Usage:
#   fable-repo-aptcheck.sh <repo-dir> <pubkey-file> [PACKAGE ...]
#
# Env:
#   FABLE_REPO_APT_ARCH   optional "APT::Architectures::=" override (default: none)
#
# Exit code 0 = all expected packages resolvable, 1 = failure.

set -euo pipefail

REPO_DIR="${1:-}"
PUBKEY="${2:-}"
shift 2 || true
EXPECTED=("$@")

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ] || die "repo dir missing: $REPO_DIR"
[ -n "$PUBKEY" ] && [ -f "$PUBKEY" ] || die "pubkey file missing: $PUBKEY"
[ "${#EXPECTED[@]}" -gt 0 ] || die "no expected packages given"
command -v apt-get >/dev/null 2>&1 || die "apt-get not available"
command -v apt-cache >/dev/null 2>&1 || die "apt-cache not available"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/lists/partial" "$TMP/cache/archives/partial"
touch "$TMP/status"
printf 'deb [signed-by=%s] file:%s ./\n' "$PUBKEY" "$REPO_DIR" > "$TMP/sources.list"

APT_OPTS=(
    -o "Dir::Etc::sourcelist=$TMP/sources.list"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::State::lists=$TMP/lists"
    -o "Dir::State::status=$TMP/status"
    -o "Dir::Cache=$TMP/cache"
    -o "APT::Get::List-Cleanup=0"
)
if [ -n "${FABLE_REPO_APT_ARCH:-}" ]; then
    APT_OPTS+=(-o "APT::Architectures::=$FABLE_REPO_APT_ARCH")
fi

echo "== apt-get update (signature enforced) =="
apt-get "${APT_OPTS[@]}" --error-on=any update

echo ""
echo "== apt-cache policy checks =="
failures=0
for p in "${EXPECTED[@]}"; do
    out="$(apt-cache "${APT_OPTS[@]}" policy "$p")"
    if [[ "$out" == *"Candidate: (none)"* ]]; then
        echo "FAIL: apt cannot resolve $p"
        failures=$((failures + 1))
    else
        candidate="$(awk '/^  Candidate:/{print $2; exit}' <<< "$out")"
        echo "PASS: apt resolves $p -> $candidate"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "RESULT: FAIL ($failures package(s) unresolvable)"
    exit 1
fi
echo "RESULT: PASS"
