#!/usr/bin/env bash
#
# fable-repo-assemble.sh
#
# Assemble a flat APT repository snapshot (fable-repo) from built .debs:
#   Packages / Packages.gz + Release / InRelease / Release.gpg,
# sign it with the fable-repo GPG key, copy the public key into the snapshot,
# and run PASS/FAIL self-checks (signature, index hashes, package presence,
# prefix scan, dependency cross-check).
#
# Environment overrides (all optional):
#   FABLE_REPO_OUTPUT_DIR      directory with built .debs (default: <repo>/output)
#   FABLE_REPO_DIR             target snapshot directory (default: <repo>/fable-repo)
#   FABLE_REPO_PUBKEY          public key file (default: <repo>/keys/fable-repo-pub.asc)
#   FABLE_REPO_ARCHS           architectures listed in Release (default: "aarch64 all")
#   FABLE_REPO_EXPECTED_PACKAGES  space-separated package names that must be indexed
#   FABLE_REPO_GPG_SIGNER      gpg --local-user key id/email (default: default key)
#   FABLE_REPO_GPG_PASSPHRASE  passphrase for the signing key (default: none)
#
# Exit code 0 = all checks passed, 1 = at least one FAIL or fatal error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR="${FABLE_REPO_OUTPUT_DIR:-$REPO_ROOT/output}"
REPO_DIR="${FABLE_REPO_DIR:-$REPO_ROOT/fable-repo}"
PUBKEY="${FABLE_REPO_PUBKEY:-$REPO_ROOT/keys/fable-repo-pub.asc}"
ARCHS="${FABLE_REPO_ARCHS:-aarch64 all}"
EXPECTED_PACKAGES="${FABLE_REPO_EXPECTED_PACKAGES:-}"
GPG_SIGNER="${FABLE_REPO_GPG_SIGNER:-}"
GPG_PASSPHRASE="${FABLE_REPO_GPG_PASSPHRASE:-}"

checks=0
failures=0

pass() { echo "PASS: $1"; checks=$((checks + 1)); }
fail() { echo "FAIL: $1"; checks=$((checks + 1)); failures=$((failures + 1)); }
die() { echo "ERROR: $*" >&2; exit 1; }

for tool in dpkg-scanpackages apt-ftparchive gzip gpg gpgv dpkg-deb sha256sum stat find; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

[ -d "$OUTPUT_DIR" ] || die "output dir not found: $OUTPUT_DIR"
shopt -s nullglob
deb_files=("$OUTPUT_DIR"/*.deb)
[ "${#deb_files[@]}" -gt 0 ] || die "no .deb files found in $OUTPUT_DIR"
[ -f "$PUBKEY" ] || die "public key not found: $PUBKEY"

echo "== Assembling fable-repo snapshot =="
echo "output dir : $OUTPUT_DIR"
echo "snapshot   : $REPO_DIR"
echo "public key : $PUBKEY"
echo "debs found : ${#deb_files[@]}"

rm -rf "$REPO_DIR"
mkdir -p "$REPO_DIR"
cp -f "$OUTPUT_DIR"/*.deb "$REPO_DIR"/

# Ship the public key in both armored and binary (keybox-friendly) forms.
cp -f "$PUBKEY" "$REPO_DIR/fable-repo-pub.asc"
if ! gpg --dearmor < "$PUBKEY" > "$REPO_DIR/fable-repo-pub.gpg" 2>/dev/null; then
    cp -f "$PUBKEY" "$REPO_DIR/fable-repo-pub.gpg"
fi

cd "$REPO_DIR"

dpkg-scanpackages -m . /dev/null > Packages 2>/dev/null || die "dpkg-scanpackages failed"
gzip -9n -c Packages > Packages.gz

apt-ftparchive release \
    -o APT::FTPArchive::Release::Origin="Fable" \
    -o APT::FTPArchive::Release::Label="Fable fable-repo" \
    -o APT::FTPArchive::Release::Suite="stable" \
    -o APT::FTPArchive::Release::Codename="fable" \
    -o "APT::FTPArchive::Release::Architectures=$ARCHS" \
    -o "APT::FTPArchive::Release::Date=$(date -u +'%a, %d %b %Y %H:%M:%S UTC')" \
    -o "APT::FTPArchive::Release::Valid-Until=$(date -u -d '+14 days' +'%a, %d %b %Y %H:%M:%S UTC')" \
    . > Release || die "apt-ftparchive release failed"

# apt-ftparchive adds a self-referential (stale) hash entry for "Release"
# itself. APT ignores it, but it would break strict hash verification below,
# so strip it from every hash section.
awk '
    /^(MD5Sum|SHA1|SHA256|SHA512):/ { in_hash=1; print; next }
    in_hash && /^[A-Za-z0-9]+:/ { in_hash=0 }
    in_hash && NF == 3 && $3 == "Release" { next }
    { print }
' Release > Release.tmp && mv Release.tmp Release

GPG_OPTS=(--batch --yes)
if [ -n "$GPG_PASSPHRASE" ]; then
    GPG_OPTS+=(--pinentry-mode loopback --passphrase "$GPG_PASSPHRASE")
fi
if [ -n "$GPG_SIGNER" ]; then
    GPG_OPTS+=(--local-user "$GPG_SIGNER")
fi
gpg "${GPG_OPTS[@]}" --clearsign -o InRelease Release
gpg "${GPG_OPTS[@]}" --armor --detach-sign -o Release.gpg Release

sha256sum *.deb Packages Packages.gz Release InRelease Release.gpg \
    fable-repo-pub.asc fable-repo-pub.gpg > SHA256SUMS

echo ""
echo "== Self-checks =="

# 1. Signature verification against the shipped public key (binary form works
#    uniformly across gpgv builds, including the Termux gpgv quirk with
#    armored keyrings).
if gpgv --keyring "$REPO_DIR/fable-repo-pub.gpg" InRelease >/dev/null 2>&1; then
    pass "InRelease signature verified with fable-repo public key"
else
    fail "InRelease signature verification failed"
fi
if gpgv --keyring "$REPO_DIR/fable-repo-pub.gpg" Release.gpg Release >/dev/null 2>&1; then
    pass "Release.gpg signature verified with fable-repo public key"
else
    fail "Release.gpg signature verification failed"
fi

# 2. Release SHA256 entries match the actual index files.
hash_ok=1
while read -r hex size file; do
    [ -n "${file:-}" ] || continue
    if [ ! -f "$file" ]; then
        echo "  detail: Release references missing file: $file"
        hash_ok=0
        continue
    fi
    actual_hex="$(sha256sum "$file" | awk '{print $1}')"
    actual_size="$(stat -c%s "$file")"
    if [ "$actual_hex" != "$hex" ] || [ "$actual_size" != "$size" ]; then
        echo "  detail: SHA256/size mismatch for $file"
        hash_ok=0
    fi
done < <(awk 'BEGIN{f=0} /^SHA256:/{f=1; next} /^SHA512:|^Files:|^Description:/{f=0} f && NF>=3 {print $1, $2, $3}' Release)
if [ "$hash_ok" -eq 1 ]; then
    pass "Release SHA256 entries match Packages/Packages.gz"
else
    fail "Release SHA256 entries do not match index files"
fi

# 3. Every .deb has an index entry and vice versa.
n_debs="$(find . -maxdepth 1 -name '*.deb' | wc -l)"
n_pkgs="$(grep -c '^Package:' Packages)"
if [ "$n_debs" -eq "$n_pkgs" ]; then
    pass "all $n_debs debs indexed ($n_pkgs Packages entries)"
else
    fail "deb count ($n_debs) != Packages entries ($n_pkgs)"
fi

# 4. Requested package names are present in the index.
if [ -n "$EXPECTED_PACKAGES" ]; then
    missing=""
    for p in $EXPECTED_PACKAGES; do
        grep -qx "Package: $p" Packages || missing="$missing $p"
    done
    if [ -z "$missing" ]; then
        pass "all expected packages present in Packages"
    else
        fail "expected packages missing from Packages:$missing"
    fi
fi

# 5. No com.termux prefix paths inside any .deb (Fable prefix requirement).
bad_prefix=""
for d in *.deb; do
    if dpkg-deb -c "$d" 2>/dev/null | grep -q '/data/data/com\.termux'; then
        bad_prefix="$bad_prefix $d"
    fi
done
if [ -z "$bad_prefix" ]; then
    pass "no /data/data/com.termux paths in any .deb"
else
    fail "com.termux paths found in debs:$bad_prefix"
fi

# 6. Dependency cross-check (informational: reports deps whose names are not
#    in this snapshot; virtual/provided names such as "sh" are expected here).
names_file="$(mktemp)"
grep '^Package:' Packages | awk '{print $2}' > "$names_file"
warned=""
for d in *.deb; do
    deps="$(dpkg-deb -f "$d" Depends 2>/dev/null || true)"
    [ -z "$deps" ] && continue
    for dep in $(printf '%s\n' "$deps" | tr ',' '\n' | sed -E 's/^[[:space:]]*([^ (|]+).*/\1/' | tr -d ' '); do
        grep -qx "$dep" "$names_file" || warned="$warned $d->$dep"
    done
done
rm -f "$names_file"
if [ -z "$warned" ]; then
    pass "Depends cross-check: all direct dependencies present in snapshot"
else
    echo "WARN: dependencies not found in snapshot (may be virtual/provided):$warned"
fi

echo ""
echo "== Summary =="
echo "self-check: $((checks - failures))/$checks PASSED, $failures FAILED"
echo "snapshot  : $REPO_DIR ($n_debs debs)"
if [ "$failures" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
