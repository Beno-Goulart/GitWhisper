import sys

import git_helpers as git
import llm, message
from ui import setup_encoding


def run(cfg, args, dry_run=False):
    diff_index = git.text(["diff", "--staged", "--name-status"])
    if not diff_index.strip():
        return 0

    added, modified, deleted, _ = git.staged_changes()
    diff_content = git.staged_diff()
    m = message.compute_message(diff_content, added, modified, deleted, cfg)

    title, body = m["title"], m["body"]
    if cfg.llm_enabled:
        lt, lb, lerr = llm.suggest(cfg, added, modified, deleted, diff_content, m)
        if lerr:
            sys.stderr.write("GitWhisper: %s\n" % lerr)
            sys.stderr.write("GitWhisper: using the heuristic message instead.\n")
        if lt:
            title, body = lt, lb

    # raw UTF-8 output (no trailing newline), matching the original suggest.
    sys.stdout.write("%s\n\n%s" % (title, body))
    sys.stdout.flush()
    return 0
