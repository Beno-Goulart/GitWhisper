import datetime

import git_helpers as git
import release_notes
from ui import out

CHANGELOG_HEADER = (
    "# Changelog\n\n"
    "All notable changes to this project will be documented in this file.\n\n"
    "Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)\n\n"
)


def _last_tag():
    out_text, rc = git.run(["describe", "--tags", "--abbrev=0"])
    return out_text.strip() if rc == 0 else ""


def run(cfg, args, dry_run=False):
    since_tag = "--since-tag" in args
    limit = 50
    if "--limit" in args:
        i = args.index("--limit")
        if i + 1 < len(args):
            try:
                limit = int(args[i + 1])
            except ValueError:
                pass

    last_tag = ""
    if since_tag:
        last_tag = _last_tag()
        if last_tag:
            log_text, rc = git.run(["log", "%s..HEAD" % last_tag, "--pretty=format:%H|%s|%ad|%an|%ae", "--date=short"])
        else:
            out("No tags found. Showing all commits.")
            log_text, rc = git.run(["log", "--pretty=format:%H|%s|%ad|%an|%ae", "--date=short", "-n", str(limit)])
    else:
        log_text, rc = git.run(["log", "--pretty=format:%H|%s|%ad|%an|%ae", "--date=short", "-n", str(limit)])

    if not log_text.strip():
        out("No commits found.")
        return 0

    types = release_notes.get_release_types(cfg)
    all_commits = release_notes.parse_commit_log(log_text)

    for c in all_commits:
        if c["type"] in types:
            types[c["type"]]["commits"].append(c)
        else:
            types["chore"]["commits"].append(c)

    if not all_commits:
        out("No conventional commits found.")
        return 0

    last_tag = _last_tag()
    current_version = last_tag.lstrip("v") if last_tag else "0.1.0"

    has_feat = len(types["feat"]["commits"]) > 0
    has_fix = len(types["fix"]["commits"]) > 0
    has_breaking = any("!" in c["message"] for c in all_commits)

    new_version = release_notes.bump_version(current_version, has_breaking, has_feat, has_fix)

    today = datetime.date.today().isoformat()

    changelog = CHANGELOG_HEADER + "## [%s](%s)\n\n" % (new_version, today)
    changelog += release_notes.build_notes(types, all_commits, cfg)

    with open("CHANGELOG.md", "w", encoding="utf-8", newline="") as fh:
        fh.write(changelog)

    out("=== Changelog generated ===")
    out("")
    out("  Version: %s" % new_version)
    out("  Commits: %d" % len(all_commits))
    out("  File:    CHANGELOG.md")
    out("")
    out("=== Preview ===")
    out("")
    lines = changelog.split("\n")[:30]
    for line in lines:
        out("  %s" % line)
    if len(changelog.split("\n")) > 30:
        out("  ...")
    return 0
