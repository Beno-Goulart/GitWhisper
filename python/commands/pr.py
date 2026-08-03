import re
import shutil
import subprocess
import webbrowser

import git_helpers as git
import release_notes
from ui import out, prompt

DEFAULT_TITLES = {
    "feat": "Features",
    "fix": "Bug Fixes",
    "perf": "Performance",
    "refactor": "Refactoring",
    "docs": "Documentation",
    "test": "Tests",
    "build": "Build",
    "ci": "CI/CD",
    "chore": "Chores",
    "style": "Style",
    "revert": "Reverts",
}


def _copy_clipboard(text):
    try:
        if shutil.which("clip"):
            p = subprocess.run(["clip"], input=text.encode("utf-8"))
            if p.returncode == 0:
                return True
        if shutil.which("pbcopy"):
            p = subprocess.run(["pbcopy"], input=text.encode("utf-8"))
            if p.returncode == 0:
                return True
    except OSError:
        pass
    return False


def run(cfg, args, dry_run=False):
    base_branch = ""
    if "--base" in args:
        i = args.index("--base")
        if i + 1 < len(args):
            base_branch = args[i + 1]
    create_pr = "create" in args

    branch = git.text(["symbolic-ref", "--short", "HEAD"]).strip()
    if not branch:
        out("Error: Not on a branch.")
        return 1

    if not base_branch:
        for try_b in ("main", "master", "develop"):
            exists, rc = git.run(["rev-parse", "--verify", try_b])
            if rc == 0:
                base_branch = try_b
                break
        if not base_branch:
            out("Error: Could not detect base branch. Use --base.")
            return 1

    merge_base, rc = git.run(["merge-base", base_branch, branch])
    if not merge_base.strip():
        out("Error: Branches %s and %s have no common ancestor." % (base_branch, branch))
        return 1

    log_text, rc = git.run(["log", "%s..%s" % (merge_base.strip(), branch), "--pretty=format:%H|%s|%ad", "--date=short", "--no-merges"])
    if not log_text.strip():
        out("No commits found between %s and %s." % (base_branch, branch))
        return 0

    types = {}
    for t, title in DEFAULT_TITLES.items():
        types[t] = {"emoji": cfg.gitmoji(t), "title": title, "commits": []}
    for t in cfg.type_titles:
        if t not in types:
            types[t] = {"emoji": cfg.gitmoji(t), "title": t, "commits": []}
        types[t]["title"] = cfg.type_titles[t]
        types[t]["emoji"] = cfg.gitmoji(t)

    all_commits = []
    for raw in log_text.splitlines():
        if not raw:
            continue
        parts = raw.split("|", 2)
        if len(parts) < 3:
            continue
        hash_, message, date = [p.strip() for p in parts]
        m = re.match(r"(\w+)(?:\(([^)]+)\))?[!]?:\s*(.+)", message)
        if not m:
            continue
        ctype = m.group(1).lower()
        scope = m.group(2) or ""
        desc = m.group(3)
        short_hash = hash_[:7]
        commit_obj = {"hash": short_hash, "scope": scope, "description": desc, "date": date}
        if ctype in types:
            types[ctype]["commits"].append(commit_obj)
        else:
            types["chore"]["commits"].append(commit_obj)
        all_commits.append(commit_obj)

    if not all_commits:
        out("No conventional commits found.")
        return 0

    summary_parts = []
    if types["feat"]["commits"]:
        feat_desc = ", ".join([c["description"] for c in types["feat"]["commits"]][:3])
        summary_parts.append("adds %s" % feat_desc)
    if types["fix"]["commits"]:
        fix_desc = ", ".join([c["description"] for c in types["fix"]["commits"]][:2])
        summary_parts.append("fixes %s" % fix_desc)
    if types["refactor"]["commits"]:
        summary_parts.append("refactors codebase")
    if summary_parts:
        joined = "; ".join(summary_parts)
        summary = joined[:1].upper() + joined[1:]
    else:
        summary = "Updates codebase"

    pr_body = "## Summary\n%s\n\n## Changes" % summary

    order = release_notes.type_order(cfg)

    for t in order:
        td = types[t]
        if not td["commits"]:
            continue
        pr_body += "\n### %s\n" % td["title"]
        for c in td["commits"]:
            emoji = td["emoji"]
            if c["scope"]:
                pr_body += "\n- %s **%s:** %s (%s)" % (emoji, c["scope"], c["description"], c["hash"])
            else:
                pr_body += "\n- %s %s (%s)" % (emoji, c["description"], c["hash"])

    pr_body += "\n"
    pr_body += "---"
    pr_body += "\n**Branch:** %s -> %s" % (branch, base_branch)
    pr_body += "\n**Commits:** %d" % len(all_commits)

    out("")
    out("=== PR Description ===")
    out("")
    for line in pr_body.split("\n"):
        out("  %s" % line)

    if not create_pr:
        out("")
        copy = prompt("  Copy to clipboard? (y/n)")
        if copy.lower() in ("y", "yes"):
            if _copy_clipboard(pr_body):
                out("")
                out("  Copied to clipboard!")
            else:
                out("")
                out("  Clipboard not available.")

    out("")
    if create_pr:
        create = "y"
    else:
        create = prompt("  Create PR now? (y/n)")
    if create.lower() in ("y", "yes"):
        title = all_commits[0]["description"]
        if len(all_commits) > 1:
            title = "%d features, %d fixes" % (len(types["feat"]["commits"]), len(types["fix"]["commits"]))
        if shutil.which("gh"):
            p = subprocess.run(
                ["gh", "pr", "create", "--title", title, "--body", "-", "--base", base_branch, "--head", branch],
                input=pr_body.encode("utf-8"),
                capture_output=True,
            )
            if p.returncode == 0:
                out("")
                out("  PR created successfully!")
            else:
                out("")
                out("  PR creation failed.")
        else:
            out("")
            out("  gh CLI not found. Opening browser...")
            remote, rc = git.run(["remote", "get-url", "origin"])
            match = re.sub(r".*[:/]([^/]+/[^/.]+)(\.git)?$", r"\1", remote.strip())
            url = "https://github.com/%s/compare/%s...%s" % (match, base_branch, branch)
            webbrowser.open(url)
    return 0
