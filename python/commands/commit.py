import os
import sys
import tempfile

import git_helpers as git
import llm, message
from ui import out, prompt


def _edit_body(body):
    edited_body = []
    i = 0
    while i < len(body):
        out("")
        out("  [%d] %s" % (i + 1, body[i]))
        edit_line = prompt("  Edit (Enter=keep, '.'=delete, '+$=add after)")
        if edit_line == ".":
            i += 1
            continue
        if edit_line == "+":
            edited_body.append(body[i])
            new_line = prompt("  New line")
            if new_line:
                edited_body.append(new_line)
            i += 1
            continue
        if edit_line == "":
            edited_body.append(body[i])
        else:
            edited_body.append(edit_line)
        i += 1
    out("")
    return edited_body


def run(cfg, args, dry_run=False):
    unstaged = git.text(["diff", "--name-only"])
    untracked = git.text(["ls-files", "--others", "--exclude-standard"])

    if unstaged.strip() or untracked.strip():
        out("")
        out("  Unstaged changes detected.")
        stage_all = prompt("  Stage all changes? (y/n)")
        if stage_all.lower() in ("y", "yes"):
            git.run(["add", "-A"])
            out("  All changes staged.")

    diff_index = git.text(["diff", "--staged", "--name-status"])
    diff_stat = git.text(["diff", "--staged", "--stat"])
    diff_content = git.staged_diff()

    if not diff_index.strip():
        out("No changes found.")
        return 0

    out("")
    out("=== Changes detected ===")
    if diff_stat:
        out(diff_stat.rstrip("\n"))
    out("")

    added, modified, deleted, renamed = git.staged_changes()
    m = message.compute_message(diff_content, added, modified, deleted, cfg)

    title = m["title"]
    body = m["body"]
    variants = m["variants"]
    llm_full = False
    detail_desc = m["detail_desc"]
    desc = m["desc"]

    if cfg.llm_enabled:
        lt, lb = llm.suggest(cfg, added, modified, deleted, diff_content, m)
        if lt:
            if cfg.llm_mode == "full":
                title, body = lt, lb
                llm_full = True
            else:
                desc = lt.split(": ", 1)[1] if ": " in lt else lt
                variants, title = message.render_variants(m, desc)
                body = message.build_body(added, modified, deleted, desc, "")

    selected = ""
    if not llm_full:
        out("=== Choose your commit message ===")
        out("")
        out("  [1] %s" % variants["simple_with_emoji"])
        out("  [2] %s" % variants["simple_without_emoji"])
        out("  [3] %s" % variants["detail_with_emoji"])
        out("  [4] %s" % variants["detail_without_emoji"])
        out("  [0] Cancel")
        out("")

        choice = prompt("  Select (0-4)")
        if choice == "1":
            selected = variants["simple_with_emoji"]
        elif choice == "2":
            selected = variants["simple_without_emoji"]
        elif choice == "3":
            selected = variants["detail_with_emoji"]
        elif choice == "4":
            selected = variants["detail_without_emoji"]
        else:
            out("")
            out("  Cancelled.")
            return 0
    else:
        selected = title

    out("")
    out("  Committing: %s" % selected)

    if not llm_full:
        body = message.build_body(added, modified, deleted, desc, detail_desc)

    if dry_run:
        out("  [DRY-RUN] Commit skipped.")
        return 0

    final_title = selected
    final_body = body.split("\n") if body else []

    while True:
        open_editor = False

        out("")
        out("=== Commit preview ===")
        out("")
        out("  %s" % final_title)
        if final_body:
            out("")
            for bl in final_body:
                out("  %s" % bl)
        out("")
        out("  [1] Commit as-is")
        out("  [2] Edit subject")
        out("  [3] Edit body")
        out("  [4] Open in editor")
        out("  [0] Cancel")
        out("")

        action = prompt("  Choose (0-4)")
        if not action:
            out("")
            out("  Cancelled.")
            return 0
        if action == "1":
            break
        elif action == "2":
            out("")
            out("  Subject: %s" % final_title)
            new_title = prompt("  New subject (Enter to keep)")
            if new_title:
                final_title = new_title
        elif action == "3":
            final_body = _edit_body(final_body)
        elif action == "4":
            open_editor = True
            break
        else:
            out("")
            out("  Cancelled.")
            return 0

    full_msg = "%s\n\n%s" % (final_title, "\n".join(final_body))

    tmp = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="", suffix=".txt", delete=False)
    tmp.write(full_msg)
    tmp.close()

    if open_editor:
        out("")
        out("  Opening editor...")
        _o, commit_rc = git.run(["commit", "-e", "-F", tmp.name])
    else:
        _o, commit_rc = git.run(["commit", "-F", tmp.name])
    os.unlink(tmp.name)

    if commit_rc == 0:
        out("")
        push = prompt("  Push to remote? (y/n)")
        if push.lower() in ("y", "yes"):
            out("")
            out("  Pushing...")
            if git.ok(["push"]):
                out("  Pushed successfully!")
            else:
                out("  Push failed.")
    else:
        out("")
        out("  Commit failed.")
    return 0
