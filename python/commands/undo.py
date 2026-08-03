import git_helpers as git
from ui import out, prompt


def run(cfg, args, dry_run=False):
    last_msg, rc = git.run(["log", "-1", "--format=%s"])
    if not last_msg.strip():
        out("Nothing to undo.")
        return 0

    out("")
    out("=== Undo last commit ===")
    out("")
    out("  Last commit: %s" % last_msg.strip())
    out("")
    out("  [1] Soft reset  - keeps changes staged")
    out("  [2] Mixed reset - unstages changes (keeps files)")
    out("  [0] Cancel")
    out("")

    choice = prompt("  Select (0-2)")
    if choice == "1":
        if git.ok(["reset", "--soft", "HEAD~1"]):
            out("")
            out("  Undone (soft). Changes are still staged.")
        else:
            out("")
            out("  Undo failed.")
    elif choice == "2":
        if git.ok(["reset", "HEAD~1"]):
            out("")
            out("  Undone (mixed). Changes are unstaged.")
        else:
            out("")
            out("  Undo failed.")
    else:
        out("")
        out("  Cancelled.")
    return 0
