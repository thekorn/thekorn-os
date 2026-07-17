#!/usr/bin/env bash
# Verify that the selected compiler belongs to the Zig 0.17.x line.
set -euo pipefail

ZIG_CMD="${ZIG_CMD:-zig}"

if ! command -v "$ZIG_CMD" >/dev/null 2>&1; then
    echo "ERROR: zig not found. Set ZIG_CMD or add zig to PATH." >&2
    exit 1
fi

version=$("$ZIG_CMD" version)

if [[ "$version" =~ ^0\.17\.[0-9]+([+-].*)?$ ]]; then
    echo "OK: Zig $version detected."
    if [[ "$version" == *-dev.* ]]; then
        echo "NOTE: development snapshot APIs may change before Zig 0.17.0."
    fi
    exit 0
fi

echo "ERROR: Zig $version detected; this skill targets Zig 0.17.x." >&2
exit 1
