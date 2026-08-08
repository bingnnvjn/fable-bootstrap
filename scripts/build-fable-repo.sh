#!/usr/bin/env bash
#
# build-fable-repo.sh
#
# Build requested packages (with dependency closure) via build-package.sh into
# output/, then assemble + sign + self-check the fable-repo snapshot.
# Intended to run inside the termux-packages builder container, e.g.:
#   ./scripts/run-docker.sh ./scripts/build-fable-repo.sh git gh openssh
#
# Subpackage names (openjdk-17-x, rust-std-aarch64-linux-android, clang,
# openssh-sftp-server, ...) resolve automatically to their parent package.
#
# Pass --build-only as the first argument to build into output/ and skip the
# snapshot assembly (used when assembly runs outside the builder container).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ARCH="${TERMUX_ARCH:-aarch64}"

build_only=0
if [ "${1:-}" = "--build-only" ]; then
    build_only=1
    shift
fi

# Normalize input: accept comma- and/or space-separated package names.
inputs=()
for raw in "$@"; do
    for p in ${raw//,/ }; do
        [ -n "$p" ] && inputs+=("$p")
    done
done
if [ "${#inputs[@]}" -eq 0 ]; then
    echo "Usage: build-fable-repo.sh PACKAGE [PACKAGE ...]" >&2
    exit 1
fi

resolve_parent() {
    local name="$1" parent=""
    if [ -d "packages/$name" ]; then
        echo "$name"
        return 0
    fi
    parent="$(find packages -maxdepth 2 -name "${name}.subpackage.sh" -print -quit 2>/dev/null \
        | sed -E 's#^packages/([^/]+)/.*#\1#')"
    if [ -n "$parent" ]; then
        echo "$parent"
        return 0
    fi
    echo "ERROR: cannot resolve '$name' to a package or subpackage in packages/" >&2
    return 1
}

parents=()
for name in "${inputs[@]}"; do
    parent="$(resolve_parent "$name")"
    seen=0
    for p in "${parents[@]:-}"; do
        [ "$p" = "$parent" ] && seen=1
    done
    [ "$seen" -eq 0 ] && parents+=("$parent")
done

echo "Requested packages : ${inputs[*]}"
echo "Parent packages    : ${parents[*]}"
echo "Architecture       : $ARCH"

./build-package.sh -a "$ARCH" "${parents[@]}"

if [ "$build_only" -eq 1 ]; then
    echo "build-only: packages built into output/, skipping snapshot assembly"
    exit 0
fi

export FABLE_REPO_OUTPUT_DIR="$REPO_ROOT/output"
export FABLE_REPO_DIR="$REPO_ROOT/fable-repo"
export FABLE_REPO_EXPECTED_PACKAGES="${inputs[*]}"
export FABLE_REPO_GPG_SIGNER="${FABLE_REPO_GPG_SIGNER:-}"
export FABLE_REPO_GPG_PASSPHRASE="${FABLE_REPO_GPG_PASSPHRASE:-}"
"$SCRIPT_DIR/fable-repo-assemble.sh"

echo ""
echo "fable-repo snapshot ready: $REPO_ROOT/fable-repo"
