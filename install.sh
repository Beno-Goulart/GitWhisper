#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/commit-msg.sh" ]; then
    echo "Error: commit-msg.sh not found in $SCRIPT_DIR"
    exit 1
fi

if [ -n "$ZSH_VERSION" ]; then
    PROFILE_FILE="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ]; then
    PROFILE_FILE="$HOME/.bashrc"
else
    PROFILE_FILE="$HOME/.profile"
fi

touch "$PROFILE_FILE"

MARKER="# >>> GitWhisper >>>"

if grep -qF "$MARKER" "$PROFILE_FILE" 2>/dev/null; then
    echo "GitWhisper is already installed in your profile."
    echo "Restart your terminal or run: source $PROFILE_FILE"
    exit 0
fi

cat >> "$PROFILE_FILE" << EOF

# >>> GitWhisper >>>
commit-msg() { bash "$SCRIPT_DIR/commit-msg.sh" "\$@"; }
commit-msg-undo() { bash "$SCRIPT_DIR/commit-msg.sh" --undo; }
changelog() { bash "$SCRIPT_DIR/changelog.sh" "\$@"; }
# <<< GitWhisper <<<
EOF

echo ""
echo "=== GitWhisper installed ==="
echo ""
echo "  Functions added to:"
echo "  $PROFILE_FILE"
echo ""
echo "  Available commands:"
printf "    commit-msg        \033[36m- generate commit message\033[0m\n"
printf "    commit-msg-undo   \033[36m- undo last commit\033[0m\n"
printf "    changelog         \033[36m- generate changelog\033[0m\n"
echo ""
echo "  Restart your terminal or run:"
echo "    source $PROFILE_FILE"
echo ""
