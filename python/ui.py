# Small IO helpers shared by every command.
# stdout is forced to UTF-8 so emoji survive pipes to hooks and on Windows.

import sys


def setup_encoding():
    for stream in (sys.stdout, sys.stderr, sys.stdin):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError, OSError):
            pass


def out(text=""):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def prompt(text=""):
    try:
        return input(text)
    except EOFError:
        return ""
