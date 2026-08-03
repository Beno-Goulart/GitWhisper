import os
import tempfile

import git_helpers as git
from ui import out, prompt


def run(cfg, args, dry_run=False):
    last_msg, rc1 = git.run(["log", "-1", "--format=%s"])
    last_body, rc2 = git.run(["log", "-1", "--format=%b"])
    if not last_msg.strip():
        out("No commits to amend.")
        return 0

    out("")
    out("=== Amend last commit ===")
    out("")
    out("  Last message: %s" % last_msg.strip())
    if last_body.strip():
        out("  Body:")
        for line in last_body.rstrip("\n").split("\n"):
            out("    %s" % line)
    out("")

    tmp = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".txt", delete=False)
    tmp.write(last_msg.strip())
    if last_body.strip():
        tmp.write("\n\n%s" % last_body.rstrip("\n"))
    tmp.close()

    out("  Opening editor to edit message...")
    _out, amend_rc = git.run(["commit", "--amend", "-F", tmp.name])
    os.unlink(tmp.name)

    if amend_rc == 0:
        out("")
        out("  Commit amended!")
        push = prompt("  Force push? (y/n)")
        if push.lower() in ("y", "yes"):
            out("")
            out("  Force pushing...")
            if git.ok(["push", "--force-with-lease"]):
                out("  Pushed successfully!")
            else:
                out("  Push failed.")
    else:
        out("")
        out("  Amend failed.")
    return 0
