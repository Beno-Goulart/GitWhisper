#!/usr/bin/env python3
# GitWhisper Python engine entry point.
# Dispatches to the requested command. Run as:  python main.py [command] [args]

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ui import setup_encoding  # noqa: E402
from config import load_config  # noqa: E402
from commands import amend, changelog, commit, help as help_cmd  # noqa: E402
from commands import init, pr, release, suggest, undo  # noqa: E402


def main(argv=None):
    setup_encoding()
    argv = list(sys.argv[1:] if argv is None else argv)

    dry_run = "--dry-run" in argv or "-n" in argv

    cmd = ""
    if argv:
        first = argv[0]
        if first in ("--dry-run", "-n"):
            argv.pop(0)
        else:
            cmd = first
            argv.pop(0)

    if cmd in ("help", "--help", "-h"):
        return help_cmd.run(None, argv)

    if not os.path.isdir(".git"):
        sys.stdout.write("Error: Not a git repository.\n")
        return 1

    cfg = load_config()

    if cmd in ("", "commit"):
        return commit.run(cfg, argv, dry_run)
    if cmd == "undo":
        return undo.run(cfg, argv, dry_run)
    if cmd == "amend":
        return amend.run(cfg, argv, dry_run)
    if cmd == "changelog":
        return changelog.run(cfg, argv, dry_run)
    if cmd == "release":
        return release.run(cfg, argv, dry_run)
    if cmd == "init":
        return init.run(cfg, argv, dry_run)
    if cmd == "suggest":
        return suggest.run(cfg, argv, dry_run)
    if cmd == "pr":
        return pr.run(cfg, argv, dry_run)

    sys.stdout.write("Unknown command: %s\n" % cmd)
    return help_cmd.run(None, argv)


if __name__ == "__main__":
    sys.exit(main())
