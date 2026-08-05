from ui import out


def run(cfg, args, dry_run=False):
    out("")
    out("=== GitWhisper ===")
    out("")
    out("  Usage:")
    out("    gitwhisper               - generate commit message")
    out("    gitwhisper commit        - generate commit message")
    out("    gitwhisper undo          - undo last commit")
    out("    gitwhisper amend         - amend last commit")
    out("    gitwhisper changelog     - generate changelog")
    out("    gitwhisper release       - create release (changelog + tag)")
    out("    gitwhisper release --push    - push commit and tag after release")
    out("    gitwhisper release --github  - also publish a GitHub Release (gh CLI)")
    out("    gitwhisper release --minor   - force minor bump (major/minor/patch)")
    out("    gitwhisper release --version 1.2.3 - use explicit version")
    out("    gitwhisper pr            - generate PR description")
    out("    gitwhisper pr --base main   - specify base branch")
    out("    gitwhisper pr create        - generate and create PR")
    out("    gitwhisper init         - create .gitwhisperconfig and install git hooks")
    out("    gitwhisper init --force - overwrite existing config and hooks")
    out("    gitwhisper config       - view/edit .gitwhisperconfig via interactive menu")
    out("    gitwhisper suggest      - print suggested message (used by hooks)")
    out("    gitwhisper --dry-run     - show message without committing")
    out("")
    return 0
