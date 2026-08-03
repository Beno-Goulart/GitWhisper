import datetime
import os
import shutil
import subprocess
import tempfile

import git_helpers as git
import release_notes
from ui import out, prompt

CHANGELOG_HEADER = (
    "# Changelog\n\n"
    "All notable changes to this project will be documented in this file.\n\n"
    "Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)\n\n"
)


def _last_tag():
    out_text, rc = git.run(["describe", "--tags", "--abbrev=0"])
    return out_text.strip() if rc == 0 else ""


def run(cfg, args, dry_run=False):
    push = "--push" in args or "-Push" in args
    publish_gh = "--github" in args or "--gh" in args or "-Github" in args
    force_type = ""
    version_override = ""
    for i, a in enumerate(args):
        if a in ("--major", "-Major"):
            force_type = "major"
        elif a in ("--minor", "-Minor"):
            force_type = "minor"
        elif a in ("--patch", "-Patch"):
            force_type = "patch"
        elif a in ("--version", "-Version") and i + 1 < len(args):
            version_override = args[i + 1]

    status, rc = git.run(["status", "--porcelain", "--untracked-files=no"])
    if status.strip():
        out("")
        out("  Working tree has uncommitted changes.")
        cont = prompt("  Continue anyway? (y/n)")
        if cont.lower() != "y":
            out("")
            out("  Cancelled.")
            return 0

    last_tag = _last_tag()
    if last_tag:
        log_text, rc = git.run(["log", "%s..HEAD" % last_tag, "--pretty=format:%H|%s|%ad|%an|%ae", "--date=short"])
    else:
        out("")
        out("  No tags found. Releasing from the beginning of history.")
        log_text, rc = git.run(["log", "--pretty=format:%H|%s|%ad|%an|%ae", "--date=short"])

    if not log_text.strip():
        out("No commits to release.")
        return 0

    types = release_notes.get_release_types(cfg)
    all_commits = release_notes.parse_commit_log(log_text)
    has_breaking = False

    for c in all_commits:
        if "!" in c["message"] or "BREAKING CHANGE" in c["message"]:
            has_breaking = True
        if c["type"] in types:
            types[c["type"]]["commits"].append(c)
        else:
            types["chore"]["commits"].append(c)

    if not all_commits:
        out("No conventional commits found since last release.")
        return 0

    current_version = last_tag.lstrip("v") if last_tag else "0.1.0"
    new_version = release_notes.bump_version(
        current_version,
        has_breaking,
        len(types["feat"]["commits"]) > 0,
        len(types["fix"]["commits"]) > 0,
        force_type=force_type,
        override=version_override,
    )

    tag_name = "v%s" % new_version

    existing_tag, rc = git.run(["tag", "-l", tag_name])
    if existing_tag.strip():
        out("Tag %s already exists." % tag_name)
        return 1

    today = datetime.date.today().isoformat()

    notes = release_notes.build_notes(types, all_commits, cfg)
    section = "## [%s](%s)\n\n%s" % (new_version, today, notes)

    changelog_file = "CHANGELOG.md"
    existing_content = ""
    if os.path.isfile(changelog_file):
        with open(changelog_file, "r", encoding="utf-8", errors="replace") as fh:
            existing_content = fh.read()

    if existing_content and "## [" in existing_content:
        idx = existing_content.index("## [")
        new_content = existing_content[:idx] + section + "\n" + existing_content[idx:]
    else:
        new_content = CHANGELOG_HEADER + "\n" + section

    out("")
    out("=== Release preview ===")
    out("")
    out("  Version:  %s" % new_version)
    out("  Commits:  %d" % len(all_commits))
    out("  Breaking: %s" % str(has_breaking).lower())
    out("")
    out("=== Changelog section ===")
    for line in section.split("\n"):
        out("  %s" % line)

    if dry_run:
        out("")
        out("  [DRY-RUN] Release skipped. No changes made.")
        return 0

    out("")
    confirm = prompt("  Proceed with release v%s? (y/n)" % new_version)
    if confirm.lower() != "y":
        out("")
        out("  Cancelled.")
        return 0

    out("")
    out("  Writing CHANGELOG.md...")
    with open(changelog_file, "w", encoding="utf-8", newline="") as fh:
        fh.write(new_content)
    git.run(["add", changelog_file])

    tmp = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="", suffix=".txt", delete=False)
    tmp.write("chore(release): %s\n\n%s" % (tag_name, notes))
    tmp.close()
    _o, commit_rc = git.run(["commit", "-F", tmp.name])
    os.unlink(tmp.name)

    if commit_rc != 0:
        out("  Release commit failed.")
        return 1

    head_short = git.text(["rev-parse", "--short", "HEAD"]).strip()
    tmp_tag = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="", suffix=".txt", delete=False)
    tmp_tag.write("%s\n\n%s" % (head_short, notes))
    tmp_tag.close()
    _o, tag_rc = git.run(["tag", "-a", tag_name, "-F", tmp_tag.name])
    os.unlink(tmp_tag.name)

    if tag_rc != 0:
        out("  Tag creation failed.")
        return 1

    out("")
    out("  Release %s created!" % tag_name)

    if push:
        push_choice = "y"
    else:
        push_choice = prompt("  Push commit and tag? (y/n)")
    if push_choice.lower() in ("y", "yes"):
        out("")
        out("  Pushing...")
        if git.rc(["push"]) != 0:
            out("  Push failed.")
            return 1
        if git.rc(["push", "origin", tag_name]) != 0:
            out("  Tag push failed.")
            return 1
        out("  Pushed successfully!")

    if shutil.which("gh"):
        if publish_gh or push:
            gh_choice = "y"
        else:
            out("")
            gh_choice = prompt("  Publish GitHub Release? (y/n)")
        if gh_choice.lower() in ("y", "yes"):
            out("")
            out("  Publishing GitHub Release %s..." % tag_name)
            tmp_notes = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="", suffix=".txt", delete=False)
            tmp_notes.write("%s\n\n%s" % (head_short, notes))
            tmp_notes.close()
            _gh = subprocess.run(["gh", "release", "create", tag_name, "--title", tag_name, "--notes-file", tmp_notes.name], capture_output=True)
            os.unlink(tmp_notes.name)
            if _gh.returncode != 0:
                out("  GitHub Release failed.")
            else:
                out("  GitHub Release published!")
    elif publish_gh:
        out("")
        out("  gh CLI not found. Install it to publish GitHub Releases.")
    return 0
