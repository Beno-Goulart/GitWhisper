# GitWhisper `help` command (Bash).

show_help() {
    echo ""
    echo "=== GitWhisper ==="
    echo ""
    echo "  Usage:"
    echo "    gitwhisper               - generate commit message"
    echo "    gitwhisper commit        - generate commit message"
    echo "    gitwhisper undo          - undo last commit"
    echo "    gitwhisper amend         - amend last commit"
    echo "    gitwhisper changelog     - generate changelog"
    echo "    gitwhisper release       - create release (changelog + tag)"
    echo "    gitwhisper release --push   - push commit and tag after release"
    echo "    gitwhisper release --github - also publish a GitHub Release (gh CLI)"
    echo "    gitwhisper release --minor  - force minor bump (major/minor/patch)"
    echo "    gitwhisper release --version 1.2.3 - use explicit version"
    echo "    gitwhisper help          - show this help"
    echo "    gitwhisper pr            - generate PR description"
    echo "    gitwhisper pr --base main   - specify base branch"
    echo "    gitwhisper --dry-run     - show message without committing"
    echo "    gitwhisper init           - create config + install smart git hooks"
    echo "    gitwhisper init --force   - recreate config + overwrite hooks"
    echo "    gitwhisper suggest        - print suggested message (used by hooks)"
    echo ""
    exit 0
}
