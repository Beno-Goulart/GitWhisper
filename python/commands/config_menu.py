# Interactive .gitwhisperconfig viewer/editor.
# Menu-driven like the commit flow: pick a section, edit values in place
# (comments and ordering are preserved), then write back on exit.

import os

from ui import out, prompt

CONFIG_PATH = ".gitwhisperconfig"

KNOWN = {
    "general": {
        "emoji": {"kind": "bool", "hint": "include emoji in generated commit messages"},
        "default": {"kind": "int1_4", "hint": "pre-filled suggestion: 1=simple+emoji, 2=simple, 3=detailed+emoji, 4=detailed"},
        "core_maintainers": {"kind": "str", "hint": "maintainers excluded from community contributors (comma-separated)"},
        "scope": {"kind": "str", "hint": "force every message to use this scope (empty = auto)"},
    },
    "hooks": {
        "prepare": {"kind": "bool", "hint": "pre-fill the commit message on `git commit`"},
        "validate": {"kind": "bool", "hint": "reject commits that do not follow Conventional Commits"},
    },
    "llm": {
        "enabled": {"kind": "bool", "hint": "use a local LLM (Ollama) to write commit descriptions"},
        "url": {"kind": "str", "hint": "OpenAI-compatible base URL"},
        "model": {"kind": "str", "hint": "model name (run `ollama list`)"},
        "mode": {"kind": "choice", "choices": ["description", "full"], "hint": "description=LLM writes the subject only, full=whole message"},
        "timeout": {"kind": "int", "hint": "seconds to wait for the LLM before falling back"},
        "max_tokens": {"kind": "int", "hint": "maximum tokens in the LLM response"},
        "language": {"kind": "str", "hint": "LLM output language, e.g. pt-BR, en (empty = model default)"},
        "api_key": {"kind": "str", "hint": "API key, only for remote providers (leave empty for Ollama)"},
    },
}

SECTION_ORDER = ["general", "hooks", "llm", "types", "scope"]
SECTION_LABELS = {
    "general": "General",
    "hooks": "Hooks",
    "llm": "LLM (Ollama)",
    "types": "Types (custom emoji/titles)",
    "scope": "Scope (directory map)",
}


def _read_lines(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            return fh.readlines()
    except OSError:
        return []


def _parsed_entries(path):
    """List of dicts {section, key, value, line_idx} for every key=value line."""
    entries = []
    lines = _read_lines(path)
    section = ""
    for idx, raw in enumerate(lines):
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if "=" in line:
            key, _, val = line.partition("=")
            entries.append({
                "section": section,
                "key": key.strip().lower(),
                "value": val.strip(),
                "line_idx": idx,
            })
    return entries


def _sections_with_entries(entries):
    sections = []
    for name in SECTION_ORDER:
        sec = [e for e in entries if e["section"] == name]
        sections.append({"name": name, "entries": sec})
    return sections


def _validate(kind, value, meta=None):
    meta = meta or {}
    if kind == "bool":
        v = value.strip().lower()
        if v in ("true", "yes", "y"):
            return "true"
        if v in ("false", "no", "n"):
            return "false"
        return None
    if kind == "int1_4":
        try:
            n = int(value)
        except (TypeError, ValueError):
            return None
        return str(n) if 1 <= n <= 4 else None
    if kind == "int":
        try:
            return str(int(value))
        except (TypeError, ValueError):
            return None
    if kind == "choice":
        v = value.strip().lower()
        choices = meta.get("choices", [])
        if v in choices:
            return v
        try:
            n = int(v)
            if 1 <= n <= len(choices):
                return choices[n - 1]
        except (TypeError, ValueError):
            pass
        return None
    return value.strip()


def _edit_value(current, meta, key_label):
    if meta["kind"] == "choice":
        out("")
        for i, c in enumerate(meta["choices"], 1):
            mark = " *" if c == current else ""
            out("  [%d] %s%s" % (i, c, mark))
        out("")
        new = prompt("  New value (Enter=keep): ")
    elif meta["kind"] == "bool":
        new = prompt("  New value true/false (Enter=keep) [%s]: " % current)
    else:
        new = prompt("  New value for %s (Enter=keep): " % key_label)
    if new.strip() == "":
        return current, False
    validated = _validate(meta["kind"], new, meta)
    if validated is None:
        out("  Invalid value. Keeping '%s'." % current)
        return current, False
    return validated, validated != current


def _show_section_menu(sec):
    meta = KNOWN.get(sec["name"], {})
    is_dynamic = sec["name"] in ("types", "scope")
    while True:
        out("")
        out("=== %s ===" % SECTION_LABELS.get(sec["name"], sec["name"]))
        out("")
        idx = 1
        entry_map = {}
        for e in sec["entries"]:
            m = meta.get(e["key"], {"kind": "str"})
            out("  [%d] %s = %s" % (idx, e["key"], e["value"] if e["value"] else "(empty)"))
            entry_map[idx] = e
            idx += 1
        out("  [%d] + add key" % idx)
        add_idx = idx
        idx += 1
        out("  [%d] - delete a key" % idx)
        del_idx = idx
        out("  [0] Back")
        out("")
        choice = prompt("  Select (0-%d): " % del_idx)
        if choice in ("", "0"):
            return
        try:
            n = int(choice)
        except (TypeError, ValueError):
            continue
        if n in entry_map:
            e = entry_map[n]
            m = meta.get(e["key"], {"kind": "str"})
            new_val, changed = _edit_value(e["value"], m, e["key"])
            if changed:
                e["value"] = new_val
                out("  Updated %s.%s = %s" % (sec["name"], e["key"], e["value"]))
        elif n == add_idx:
            if is_dynamic:
                out("")
                key = prompt("  Key (e.g. feat, security / src, api): ")
                key = key.strip().lower()
                if key:
                    value = prompt("  Value: ").strip()
                    if not any(x["key"] == key for x in sec["entries"]):
                        sec["entries"].append({
                            "section": sec["name"], "key": key,
                            "value": value, "line_idx": -1,
                        })
                        out("  Added %s.%s" % (sec["name"], key))
            else:
                known = [k for k in sorted(meta) if not any(x["key"] == k for x in sec["entries"])]
                if not known:
                    out("  All known keys are already present.")
                    continue
                out("")
                for i, k in enumerate(known, 1):
                    out("  [%d] %s" % (i, k))
                out("")
                pick = prompt("  Which key? (0=custom): ")
                if pick.isdigit() and 1 <= int(pick) <= len(known):
                    new_key = known[int(pick) - 1]
                elif pick.strip() == "":
                    continue
                else:
                    new_key = pick.strip().lower()
                new_val, _ = _edit_value("", meta.get(new_key, {"kind": "str"}), new_key)
                if not any(x["key"] == new_key for x in sec["entries"]):
                    sec["entries"].append({
                        "section": sec["name"], "key": new_key,
                        "value": new_val, "line_idx": -1,
                    })
                    out("  Added %s.%s" % (sec["name"], new_key))
        elif n == del_idx:
            out("")
            for i, e in enumerate(sec["entries"], 1):
                out("  [%d] %s = %s" % (i, e["key"], e["value"]))
            out("  [0] Back")
            out("")
            pick = prompt("  Delete which key? ")
            if pick.isdigit() and 1 <= int(pick) <= len(sec["entries"]):
                removed = sec["entries"].pop(int(pick) - 1)
                out("  Deleted %s.%s" % (sec["name"], removed["key"]))


def render(path, sections, orig_lines):
    """Build the new file contents from the edited sections. Pure, testable."""
    parsed = _parsed_entries(path)
    existing = {}
    parsed_by_key = {}
    for e in parsed:
        existing[e["line_idx"]] = (e["section"], e["key"])
        parsed_by_key[(e["section"], e["key"])] = e

    current = {}
    for sec in sections:
        for e in sec["entries"]:
            current[(e["section"], e["key"])] = e

    new_lines = []
    for idx, raw in enumerate(orig_lines):
        if idx in existing:
            sec_key = existing[idx]
            if sec_key in current:
                e = current[sec_key]
                orig_e = parsed_by_key.get(sec_key)
                if orig_e is not None and orig_e["value"] == e["value"]:
                    new_lines.append(raw)
                else:
                    new_lines.append("%-15s = %s\n" % (e["key"], e["value"]))
            continue  # deleted entry: drop the line
        new_lines.append(raw)

    for sec in sections:
        for e in sec["entries"]:
            if e["line_idx"] >= 0:
                continue
            header_at = None
            last_entry_at = None
            for idx, raw in enumerate(new_lines):
                if raw.strip() == "[%s]" % sec["name"]:
                    header_at = idx
                    last_entry_at = None
                    continue
                if header_at is not None:
                    if raw.strip().startswith("["):
                        break
                    if "=" in raw and not raw.strip().startswith(("#", ";")):
                        last_entry_at = idx
            line = "%s = %s\n" % (e["key"], e["value"])
            if last_entry_at is not None:
                new_lines.insert(last_entry_at + 1, line)
            elif header_at is not None:
                new_lines.insert(header_at + 1, line)
            else:
                new_lines.append("\n[%s]\n" % sec["name"])
                new_lines.append(line)
    return new_lines


def run(cfg, args, dry_run=False):
    if not os.path.isfile(CONFIG_PATH):
        out("")
        out("  No %s found. Run `gitwhisper init` to create it." % CONFIG_PATH)
        return 1

    orig_lines = _read_lines(CONFIG_PATH)
    sections = _sections_with_entries(_parsed_entries(CONFIG_PATH))

    while True:
        out("")
        out("=== GitWhisper Configuration ===")
        out("")
        out("  File: %s" % CONFIG_PATH)
        out("")
        for i, sec in enumerate(sections, 1):
            out("  [%d] %s" % (i, SECTION_LABELS.get(sec["name"], sec["name"])))
        out("  [0] Exit")
        out("")
        choice = prompt("  Select (0-%d): " % len(sections))
        if choice == "":
            break
        try:
            n = int(choice)
        except (TypeError, ValueError):
            continue
        if n == 0:
            break
        if 1 <= n <= len(sections):
            _show_section_menu(sections[n - 1])

    new_lines = render(CONFIG_PATH, sections, orig_lines)
    if new_lines != orig_lines:
        with open(CONFIG_PATH, "w", encoding="utf-8", newline="") as fh:
            fh.writelines(new_lines)
        out("")
        out("  Config saved to %s" % CONFIG_PATH)
    else:
        out("")
        out("  No changes made.")
    return 0
