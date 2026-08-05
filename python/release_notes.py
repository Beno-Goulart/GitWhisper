# Changelog/release helpers: type registry, git-log parsing and note rendering.
# Port of Get-ReleaseTypes / Build-ReleaseNotes / Format-ReleaseBullet.

import re

import detect
from config import DEFAULT_RELEASE_TITLES


def get_release_types(cfg):
    types = {t: {"title": title, "commits": []} for t, title in DEFAULT_RELEASE_TITLES.items()}
    for t in cfg.type_titles:
        if t not in types:
            types[t] = {"title": t, "commits": []}
        types[t]["title"] = cfg.type_titles[t]
    for t in cfg.type_order:
        if t not in types:
            types[t] = {"title": t, "commits": []}
    return types


def type_order(cfg):
    order = list(cfg.type_order)
    for t in ("feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert"):
        if t not in order:
            order.append(t)
    return order


def format_bullet(commit):
    line = "- %s" % commit["description"]
    if commit.get("pr"):
        line += " (#%s)" % commit["pr"]
    return line


def parse_commit_log(log_text):
    """Parse `%H|%s|%ad|%an|%ae` log lines into commit dicts."""
    commits = []
    for raw in log_text.splitlines():
        if not raw:
            continue
        parts = raw.split("|", 4)
        if len(parts) < 5:
            continue
        hash_, message, date, author_name, author_email = [p.strip() for p in parts]
        m = re.match(r"^\W*(\w+)(?:\(([^)]+)\))?[!]?:\s*(.+)", message)
        if not m:
            continue
        ctype = m.group(1).lower()
        scope = m.group(2) or ""
        desc = m.group(3)
        short_hash = hash_[:7]
        pr = ""
        pr_m = re.search(r"\(#(\d+)\)\s*$", desc)
        if pr_m:
            pr = pr_m.group(1)
            desc = desc[: pr_m.start()].rstrip()
        commits.append({
            "hash": short_hash,
            "message": message,
            "scope": scope,
            "description": desc,
            "type": ctype,
            "date": date,
            "pr": pr,
            "author_user": detect.get_github_username(author_name, author_email),
        })
    return commits


def build_notes(types, all_commits, cfg):
    """Render the release notes (areas grouped by scope, contributors section)."""
    areas = {}
    for c in all_commits:
        area = c["scope"] or "General"
        areas.setdefault(area, {})
        areas[area].setdefault(c["type"], []).append(c)

    area_stats = [(key, sum(len(lst) for lst in areas[key].values())) for key in areas]
    area_stats.sort(key=lambda kv: kv[1], reverse=True)
    area_order = [k for k, _ in area_stats if k != "General"] + [k for k, _ in area_stats if k == "General"]

    order = type_order(cfg)

    notes = ""
    for area in area_order:
        display = area[:1].upper() + area[1:]
        if notes:
            notes += "\n"
        notes += "### %s\n\n" % display
        for t in order:
            if t not in areas[area]:
                continue
            title = types[t]["title"]
            notes += "#### %s\n\n" % title
            for commit in areas[area][t]:
                notes += format_bullet(commit) + "\n"
            notes += "\n"

    contributor_map = {}
    for c in all_commits:
        if not c["author_user"]:
            continue
        contributor_map.setdefault(c["author_user"], []).append(c)

    community = [u for u in contributor_map if u not in cfg.core_maintainers]
    community.sort(key=lambda u: len(contributor_map[u]), reverse=True)

    if community:
        if notes:
            notes += "\n"
        notes += "### Contributors\n\n"
        noun = "contributor" if len(community) == 1 else "contributors"
        notes += "Thank you to %d community %s:\n\n" % (len(community), noun)
        for u in community:
            notes += "@%s\n" % u
            for c in sorted(contributor_map[u], key=lambda c: c["date"]):
                subject = c["type"]
                if c["scope"]:
                    subject += "(%s)" % c["scope"]
                subject += ": %s" % c["description"]
                if c["pr"]:
                    subject += " (#%s)" % c["pr"]
                notes += "- %s\n" % subject
            notes += "\n"

    all_users = sorted(contributor_map, key=lambda u: len(contributor_map[u]), reverse=True)
    if all_users:
        notes += "**Contributors:** %s\n" % ", ".join("@%s" % u for u in all_users)

    return notes


def bump_version(current, has_breaking, has_feat, has_fix, force_type="", override=""):
    if override:
        return override.lstrip("v")
    parts = [int(p) if p.isdigit() else 0 for p in current.lstrip("v").split(".")]
    while len(parts) < 3:
        parts.append(0)
    major, minor, patch = parts[:3]
    if force_type == "major":
        return "%d.0.0" % (major + 1)
    if force_type == "minor":
        return "%d.%d.0" % (major, minor + 1)
    if force_type == "patch":
        return "%d.%d.%d" % (major, minor, patch + 1)
    if has_breaking:
        return "%d.0.0" % (major + 1)
    if has_feat:
        return "%d.%d.0" % (major, minor + 1)
    if has_fix:
        return "%d.%d.%d" % (major, minor, patch + 1)
    return current.lstrip("v")
