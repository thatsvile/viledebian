#!/bin/bash
# Build release viledesktop binaries and stage them under dist/<arch>/.
# Maintainer helper: run from a checkout, then commit dist/ for install.sh
# "bundled" installs. Does not touch ~/.local/bin.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)
ARCH=$(uname -m)
OUT="$REPO_ROOT/dist/$ARCH"
BINS=(vile viledaemon vilebar vilecolors vilewall vileshot vilefox)

case "$ARCH" in
    x86_64 | aarch64) ;;
    *)
        echo "ERROR: unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

if [[ ! -f "$SCRIPT_DIR/Cargo.toml" ]]; then
    echo "ERROR: viledesktop Cargo.toml missing at $SCRIPT_DIR" >&2
    exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo not found; install rustup first." >&2
    exit 1
fi

echo "Building viledesktop release workspace..."
(cd "$SCRIPT_DIR" && cargo build --release --workspace)

mkdir -p "$OUT"
for bin in "${BINS[@]}"; do
    src="$SCRIPT_DIR/target/release/$bin"
    if [[ ! -x "$src" ]]; then
        echo "ERROR: missing $src" >&2
        exit 1
    fi
    cp "$src" "$OUT/$bin"
    chmod +x "$OUT/$bin"
    echo "  staged $bin ($(stat -c %s "$OUT/$bin") bytes)"
done

if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$REPO_ROOT" rev-parse --short=12 HEAD:viledesktop >"$OUT/VERSION" 2>/dev/null \
        || git -C "$REPO_ROOT" rev-parse --short=12 HEAD >"$OUT/VERSION"
else
    echo "unknown" >"$OUT/VERSION"
fi
date -u +"%Y-%m-%dT%H:%M:%SZ" >"$OUT/BUILT_AT"

echo "Packed into $OUT"
cat "$OUT/VERSION"
