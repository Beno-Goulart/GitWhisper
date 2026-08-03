#!/usr/bin/env bash
# GitWhisper entry point.
# Thin wrapper that forwards to the Python engine in ./python.
set -e

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENGINE=""
for base in "$SOURCE_DIR" "$HOME/.gitwhisper"; do
    if [ -f "$base/python/main.py" ]; then
        ENGINE="$base/python/main.py"
        break
    fi
done

if [ -z "$ENGINE" ]; then
    echo "Error: GitWhisper python engine not found." >&2
    exit 1
fi

PYTHON_BIN=""
for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if "$candidate" --version >/dev/null 2>&1; then
            PYTHON_BIN="$candidate"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "Error: python not found in PATH. Install Python 3 to use GitWhisper." >&2
    exit 1
fi

export PYTHONIOENCODING="utf-8"
exec "$PYTHON_BIN" "$ENGINE" "$@"
