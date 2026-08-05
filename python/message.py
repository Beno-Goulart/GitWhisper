# Message generation: the shared `Get-SuggestedMessage` port used by both the
# `suggest` and `commit` commands.

import os
import re

import detect


def _dedup(items):
    seen = []
    for it in items:
        if it not in seen:
            seen.append(it)
    return seen


def _lines_filter(content, prefix):
    if not content:
        return ""
    return "\n".join(
        l for l in content.split("\n")
        if l.startswith(prefix) and not l.startswith(prefix * 2)
    )


def _first_hook_names(added_lines):
    names = []
    for line in added_lines.split("\n"):
        m = re.search(r"(\w+)\s*\(", line)
        if m and m.group(1).startswith("use") and m.group(1) not in names:
            names.append(m.group(1))
        if len(names) >= 3:
            break
    return ", ".join(names)


def compute_message(diff_content, added, modified, deleted, cfg):
    """Full heuristic message computation (scope + type + details + variants)."""
    all_files = added + modified

    self_script = any(
        re.search(r"gitwhisper|^install\.(ps1|sh)$", f) for f in all_files
    )

    scope = detect.get_scope(all_files)
    if not scope:
        scope = detect.get_branch_scope()

    if cfg.forced_scope:
        scope = cfg.forced_scope
    elif cfg.scope_map:
        for pat in cfg.scope_map:
            for f in all_files:
                if f.startswith(pat):
                    scope = cfg.scope_map[pat]
                    break
            if scope:
                break

    result = detect.detect_commit_type(
        added,
        modified,
        deleted,
        [f.lower() for f in all_files],
        [f.lower() for f in modified],
        [f.lower() for f in deleted],
        diff_content,
        self_script,
    )

    type_name = result["type"]
    desc = result["desc"]

    if not result["strong"]:
        branch_type = detect.get_branch_type()
        if branch_type:
            type_name = branch_type

    added_lines = _lines_filter(diff_content, "+")
    removed_lines = _lines_filter(diff_content, "-")
    if self_script:
        added_lines = detect.remove_literal_strings(added_lines)
        removed_lines = detect.remove_literal_strings(removed_lines)

    detail_parts = []

    new_params = re.findall(r"param\(\s*\[.*?\]\s*\$+(\w+)", added_lines)
    if new_params:
        names = ", ".join(_dedup(new_params))
        detail_parts.append("adds -%s parameter" % names)

    new_bash_flags = re.findall(r'"--?(\w+)"', added_lines)
    if new_bash_flags:
        names = ", ".join(_dedup([n for n in new_bash_flags if n not in ("y", "n", "yes", "no")]))
        if names:
            detail_parts.append("adds --%s flag" % names)

    added_funcs = re.findall(r"function\s+([\w-]+)\s*\{", added_lines)
    if added_funcs:
        names = ", ".join(_dedup(added_funcs)[:3])
        detail_parts.append("adds %s function" % names)

    added_bash_funcs = re.findall(r"([\w_]+)\s*\(\)\s*\{", added_lines)
    if added_bash_funcs:
        names = ", ".join(_dedup([n for n in added_bash_funcs if n not in ("contains_pattern", "count_matches")])[:3])
        detail_parts.append("adds %s function" % names)

    has_high_priority = len(detail_parts) >= 2

    if not has_high_priority:
        git_ops = re.findall(r"git\s+(reset|commit|push|pull|merge|rebase|stash|tag|branch|checkout|diff|log|status|add|rm|mv)", added_lines)
        if git_ops:
            ops = ", ".join(_dedup(git_ops)[:3])
            detail_parts.append("adds git %s" % ops)

    if not has_high_priority:
        write_host = re.findall(r'Write-Host\s+"([^"]{5,50})"', added_lines)
        if write_host:
            msgs = _dedup([
                re.sub(r"\s+", " ", m)
                for m in write_host
                if not re.search(r"^(Error|Warning|Pushing|Committing|Select|Cancel)", m)
            ])[:2]
            if msgs:
                detail_parts.append("adds %s messages" % ", ".join(msgs))

    added_imports = re.findall(r"(?:import|require)\s*\{?\s*([\w]+)", added_lines)
    if added_imports:
        names = ", ".join(_dedup(added_imports)[:3])
        detail_parts.append("adds %s import" % names)

    added_classes = re.findall(r"(?:class)\s+(\w+)", added_lines)
    if added_classes:
        names = ", ".join(_dedup(added_classes))
        detail_parts.append("adds %s class" % names)

    added_routes = re.findall(r"(?:router|Route|path)\s*\(\s*['\"]([^'\"]+)", added_lines)
    if added_routes:
        paths = ", ".join(_dedup(added_routes))
        detail_parts.append("adds %s route" % paths)

    added_hooks = re.findall(r"(useState|useEffect|useContext|useReducer|useMemo|useCallback|useRef)\s*\(", added_lines)
    if added_hooks:
        hook_names = _first_hook_names(added_lines)
        if hook_names:
            detail_parts.append("adds %s" % hook_names)

    if not detail_parts:
        script_files, doc_files, config_files, other_files = [], [], [], []
        for f in (added + modified):
            ext = os.path.splitext(f)[1].lower()
            name = os.path.basename(f).lower()
            base = os.path.splitext(os.path.basename(f))[0]
            if re.search(r"\.(ps1|sh|py|rb|js|ts)$", ext) or re.search(r"commit-msg|changelog", name):
                script_files.append(base)
            elif re.search(r"\.(md|mdx|rst|txt)$", ext) or re.search(r"readme|changelog|contributing|license", name):
                doc_files.append(base)
            elif re.search(r"(package\.json|dockerfile|makefile|\.gitignore|\.editorconfig|tsconfig)", name):
                config_files.append(base)
            else:
                other_files.append(base)

        mix_parts = []
        if script_files:
            mix_parts.append("scripts (%s)" % ", ".join(script_files))
        if doc_files:
            mix_parts.append("docs (%s)" % ", ".join(doc_files))
        if config_files:
            mix_parts.append("config (%s)" % ", ".join(config_files))
        if other_files:
            mix_parts.append(", ".join(other_files[:3]))

        if mix_parts:
            detail_parts.append("updates %s" % " and ".join(mix_parts))
        elif deleted:
            del_names = ", ".join([os.path.basename(f) for f in deleted][:2])
            detail_parts.append("removes %s" % del_names)

    detail_desc = " and ".join(
        _dedup([re.sub(r"\s{2,}", " ", p) for p in detail_parts[:2]])
    )

    emoji_on = cfg.general_emoji
    emoji = cfg.gitmoji(type_name)

    if scope:
        simple_with_emoji = "%s %s(%s): %s" % (emoji, type_name, scope, desc)
        simple_without_emoji = "%s(%s): %s" % (type_name, scope, desc)
        detail_with_emoji = "%s %s(%s): %s" % (emoji, type_name, scope, detail_desc)
        detail_without_emoji = "%s(%s): %s" % (type_name, scope, detail_desc)
    else:
        simple_with_emoji = "%s %s: %s" % (emoji, type_name, desc)
        simple_without_emoji = "%s: %s" % (type_name, desc)
        detail_with_emoji = "%s %s: %s" % (emoji, type_name, detail_desc)
        detail_without_emoji = "%s: %s" % (type_name, detail_desc)

    default = cfg.general_default
    variants = {
        1: simple_with_emoji if emoji_on else simple_without_emoji,
        2: simple_without_emoji,
        3: detail_with_emoji if emoji_on else detail_without_emoji,
        4: detail_without_emoji,
    }
    title = variants[default]

    body = build_body(added, modified, deleted, desc, detail_desc)

    return {
        "type": type_name,
        "desc": desc,
        "detail_desc": detail_desc,
        "scope": scope,
        "variants": {
            "simple_with_emoji": simple_with_emoji,
            "simple_without_emoji": simple_without_emoji,
            "detail_with_emoji": detail_with_emoji,
            "detail_without_emoji": detail_without_emoji,
        },
        "emoji": emoji,
        "emoji_on": emoji_on,
        "title": title,
        "body": body,
        "default": default,
    }


def render_variants(m, desc, detail_desc=None):
    """Recompute the four title variants from a message dict + a new description
    (used when the LLM replaces the heuristic description)."""
    if detail_desc is None:
        detail_desc = m["detail_desc"]
    emoji = m["emoji"]
    type_name = m["type"]
    scope = m["scope"]
    if scope:
        sw = "%s %s(%s): %s" % (emoji, type_name, scope, desc)
        so = "%s(%s): %s" % (type_name, scope, desc)
        dw = "%s %s(%s): %s" % (emoji, type_name, scope, detail_desc)
        do = "%s(%s): %s" % (type_name, scope, detail_desc)
    else:
        sw = "%s %s: %s" % (emoji, type_name, desc)
        so = "%s: %s" % (type_name, desc)
        dw = "%s %s: %s" % (emoji, type_name, detail_desc)
        do = "%s: %s" % (type_name, detail_desc)
    emoji_on = m["emoji_on"]
    default = m["default"]
    variants = {
        "simple_with_emoji": sw if emoji_on else so,
        "simple_without_emoji": so,
        "detail_with_emoji": dw if emoji_on else do,
        "detail_without_emoji": do,
    }
    title = {
        1: variants["simple_with_emoji"],
        2: variants["simple_without_emoji"],
        3: variants["detail_with_emoji"],
        4: variants["detail_without_emoji"],
    }[default]
    return variants, title


def build_body(added, modified, deleted, desc, detail_desc):
    body_parts = []
    if added:
        body_parts.append("Added:")
        body_parts += ["  - %s" % f for f in added]
    if modified:
        body_parts.append("Modified:")
        body_parts += ["  - %s" % f for f in modified]
    if deleted:
        body_parts.append("Removed:")
        body_parts += ["  - %s" % f for f in deleted]
    body_parts.append("")
    body_parts.append("Change summary: %s" % desc)
    if detail_desc and detail_desc != desc:
        body_parts.append("Details: %s" % detail_desc)
    return "\n".join(body_parts)
