# Interactive .gitwhisperconfig viewer/editor.
# Menu-driven like the commit flow: pick a section, edit values in place
# (comments and ordering are preserved), then write back on exit.

import os

from config import read_raw_config
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


def _validate(kind, value, meta):
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
        choices = meta["choices"]
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


def _prompt_new_key(meta, is_dynamic):
    out("")
    if is_dynamic:
        key = prompt("  Key (e.g. feat, security / src, api): ")
    else:
        key = prompt("  Key: ")
    key = key.strip().lower()
    if not key:
        return None, None
    if meta["kind"] == "choice":
        out("")
        for i, c in enumerate(meta["choices"], 1):
            out("  [%d] %s" % (i, c))
        out("")
        value = prompt("  Value: ")
    else:
        value = prompt("  Value: ")
    validated = _validate(meta["kind"], value, meta)
    if validated is None:
        out("  Invalid value. Not added.")
        return None, None
    return key, validated


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
            label = e["key"]
            m = meta.get(e["key"], {"kind": "str"})
            out("  [%d] %s = %s" % (idx, label, e["value"] if e["value"] else "(empty)"))
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
                new_key, new_val = _prompt_new_key({"kind": "str"}, True)
                if new_key:
                    sec["entries"].append({
                        "section": sec["name"], "key": new_key,
                        "value": new_val or "", "line_idx": -1,
                    })
                    out("  Added %s.%s" % (sec["name"], new_key))
            else:
                known = [k for k in sorted(meta) if not sec["entries"] or all(x["key"] != k for x in sec["entries"])]
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


def _write_back(path, sections, orig_lines):
    lines = list(orig_lines)
    for sec in sections:
        for e in sec["entries"]:
            line = "%-15s = %s" % (e["key"], e["value"])
            if e["line_idx"] >= 0 and e["line_idx"] < len(lines):
                lines[e["line_idx"]] = line + "\n"
    for sec in sections:
        for e in sec["entries"]:
            if e["line_idx"] >= 0:
                continue
            header_idx = None
            last_idx = None
            for idx, raw in enumerate(lines):
                if raw.strip() == "[%s]" % sec["name"]:
                    header_idx = idx
                if header_idx is not None and "=" in raw and not raw.strip().startswith(("#", ";")):
                    if raw.strip().startswith(("[",)):
                        continue
                    key_part = raw.partition("=")[0].strip().lower()
                    if key_part == e["key"]:
                        last_idx = idx
            line = "%s = %s\n" % (e["key"], e["value"])
            if last_idx is not None:
                lines.insert(last_idx + 1, line)
            elif header_idx is not None:
                lines.insert(header_idx + 1, line)
            else:
                lines.append("\n[%s]\n" % sec["name"])
                lines.append(line)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.writelines(lines)


def run(cfg, args, dry_run=False):
    if not os.path.isfile(CONFIG_PATH):
        out("")
        out("  No %s found. Run `gitwhisper init` to create it." % CONFIG_PATH)
        return 1

    orig_lines = _read_lines(CONFIG_PATH)
    entries = _parsed_entries(CONFIG_PATH)
    sections = _sections_with_entries(entries)

    changed = False
    while True:
        out("")
        out("=== GitWhisper Configuration ===")
        out("")
        out("  File: %s" % CONFIG_PATH)
        out("")
        for i, sec in enumerate(sections, 1):
            out("  [%d] %s" % (i, SECTION_LABELS.get(sec["name"], sec["name"])))
        out("  [0] Save & exit" if changed else "  [0] Exit")
        out("")
        choice = prompt("  Select (0-%d): " % len(sections))
        if choice == "" or int(choice or 0) == 0:
            break
        try:
            n = int(choice)
        except (TypeError, ValueError):
            continue
        if 1 <= n <= len(sections):
            before = [e["value"] for e in sections[n - 1]["entries"]]
            _show_section_menu(sections[n - 1])
            after = [e["value"] for e in sections[n - 1]["entries"]]
            if before != after or len(sections[n - 1]["entries"]) != len(
                [e for e in _parsed_entries(CONFIG_PATH) if e["section"] == sections[n - 1]["name"]]
            ):
                changed = True

    if changed:
        _write_back(CONFIG_PATH, sections, orig_lines)
        out("")
        out("  Config saved to %s" % CONFIG_PATH)
    else:
        out("")
        out("  No changes made.")
    return 0
