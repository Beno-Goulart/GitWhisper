# GitWhisper configuration loader.
# Parses .gitwhisperconfig (INI-style, matching the original PowerShell/bash
# parser) and exposes typed settings shared by every command.

import os

DEFAULT_TYPE_ORDER = ["feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert"]

DEFAULT_GITMOJI = {
    "feat": "\u2728",        # ✨
    "fix": "\U0001F41B",     # 🐛
    "docs": "\U0001F4DD",    # 📝
    "style": "\U0001F484",   # 💄
    "refactor": "\u267B\uFE0F",  # ♻️
    "perf": "\u26A1",        # ⚡
    "test": "\u2705",        # ✅
    "build": "\U0001F527",   # 🔧
    "ci": "\U0001F477",      # 👷
    "chore": "\U0001F528",   # 🔨
    "db": "\U0001F5C2\uFE0F",  # 🗃️
    "revert": "\u23EA",      # ⏪
}

DEFAULT_RELEASE_TITLES = {
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


class Config:
    def __init__(self):
        self.general_emoji = True
        self.general_default = 1
        self.core_maintainers = []
        self.forced_scope = ""
        self.type_emoji = {}
        self.type_titles = {}
        self.type_order = list(DEFAULT_TYPE_ORDER)
        self.type_order_hints = {}
        self.scope_map = {}
        self.hooks_prepare = True
        self.hooks_validate = True
        self.llm_enabled = False
        self.llm_url = "http://localhost:11434/v1"
        self.llm_model = "llama3.2"
        self.llm_mode = "description"
        self.llm_timeout = 30
        self.llm_max_tokens = 150
        self.llm_api_key = ""

    def gitmoji(self, type_name):
        emoji = DEFAULT_GITMOJI.get(type_name, "\U0001F528")  # 🔨 fallback
        return self.type_emoji.get(type_name, emoji)

    def release_title(self, type_name):
        title = DEFAULT_RELEASE_TITLES.get(type_name, type_name)
        return self.type_titles.get(type_name, title)


def read_raw_config(path=".gitwhisperconfig"):
    """Parse the config file into {"section.key": value} (original parser)."""
    cfg = {}
    if not os.path.isfile(path):
        return cfg
    section = ""
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            lines = fh.readlines()
    except OSError:
        return cfg
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if "=" in line:
            key, _, val = line.partition("=")
            key = key.strip().lower()
            val = val.strip()
            cfg["%s.%s" % (section, key)] = val
    return cfg


def load_config(path=".gitwhisperconfig"):
    cfg = Config()
    raw = read_raw_config(path)

    if raw.get("general.emoji", "").lower() == "false":
        cfg.general_emoji = False

    if "general.default" in raw:
        try:
            d = int(raw["general.default"])
            if 1 <= d <= 4:
                cfg.general_default = d
        except (TypeError, ValueError):
            pass

    if raw.get("general.core_maintainers", ""):
        cfg.core_maintainers = [
            u.strip() for u in raw["general.core_maintainers"].split(",") if u.strip()
        ]

    if raw.get("general.scope", ""):
        cfg.forced_scope = raw["general.scope"]

    order_hints = {}
    for key, val in raw.items():
        if not key.startswith("types."):
            continue
        rest = key[len("types."):]
        if rest.endswith(".order"):
            base = rest[: -len(".order")]
            try:
                order_hints[base] = int(val)
            except (TypeError, ValueError):
                pass
        else:
            parts = val.split("|")
            cfg.type_emoji[rest] = parts[0].strip()
            if len(parts) > 1 and parts[1].strip():
                cfg.type_titles[rest] = parts[1].strip()
            if rest not in cfg.type_order:
                cfg.type_order.append(rest)
    cfg.type_order_hints = order_hints

    if order_hints:
        cfg.type_order = sorted(cfg.type_order, key=lambda t: order_hints.get(t, 999))

    for key, val in raw.items():
        if key.startswith("scope."):
            cfg.scope_map[key[len("scope."):]] = val

    if raw.get("hooks.prepare", "").lower() == "false":
        cfg.hooks_prepare = False
    if raw.get("hooks.validate", "").lower() == "false":
        cfg.hooks_validate = False

    if raw.get("llm.enabled", "").lower() == "true":
        cfg.llm_enabled = True
    if raw.get("llm.url", ""):
        cfg.llm_url = raw["llm.url"]
    if raw.get("llm.model", ""):
        cfg.llm_model = raw["llm.model"]
    if raw.get("llm.mode", ""):
        cfg.llm_mode = raw["llm.mode"]
    if raw.get("llm.timeout", ""):
        try:
            cfg.llm_timeout = int(raw["llm.timeout"])
        except (TypeError, ValueError):
            pass
    if raw.get("llm.max_tokens", ""):
        try:
            cfg.llm_max_tokens = int(raw["llm.max_tokens"])
        except (TypeError, ValueError):
            pass
    if raw.get("llm.api_key", ""):
        cfg.llm_api_key = raw["llm.api_key"]

    return cfg
