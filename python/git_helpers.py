# Thin wrappers around `git` subprocess calls.
# Mirrors how the original PowerShell/bash modules invoked git (stdout text,
# stderr ignored, return code captured).

import subprocess


def _run(args, cwd=None, input_data=None):
    p = subprocess.run(
        ["git", *args],
        cwd=cwd,
        input=input_data,
        capture_output=True,
    )
    stdout = p.stdout.decode("utf-8", "replace") if p.stdout else ""
    return stdout, p.returncode


def run(args, cwd=None, input_data=None):
    """Run git; returns (stdout text, return code). stderr is ignored."""
    return _run(args, cwd, input_data)


def text(args, cwd=None):
    """Run git and return stdout text (ignores failure)."""
    return _run(args, cwd)[0]


def lines(args, cwd=None):
    """Run git and return (stdout lines, return code)."""
    out, rc = _run(args, cwd)
    return out.splitlines(), rc


def ok(args, cwd=None, input_data=None):
    """Run git and return True when the exit code is 0."""
    return _run(args, cwd, input_data)[1] == 0


def rc(args, cwd=None, input_data=None):
    return _run(args, cwd, input_data)[1]


def staged_changes(cwd=None):
    """Parse `git diff --staged --name-status` into (added, modified, deleted, renamed)."""
    out, _rc = _run(["diff", "--staged", "--name-status"], cwd)
    added, modified, deleted, renamed = [], [], [], []
    for line in out.splitlines():
        parts = line.split("\t")
        if not parts or not parts[0].strip():
            continue
        status = parts[0].strip()
        fname = parts[-1].strip()
        if status.startswith("A"):
            added.append(fname)
        elif status.startswith("M"):
            modified.append(fname)
        elif status.startswith("D"):
            deleted.append(fname)
        elif status.startswith("R"):
            renamed.append(fname)
    return added, modified, deleted, renamed


def staged_diff(cwd=None):
    """The `git diff --staged` text (joined with newlines, like the original)."""
    out, _rc = _run(["diff", "--staged"], cwd)
    return out.rstrip("\n")
