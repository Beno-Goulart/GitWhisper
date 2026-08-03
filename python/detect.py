# Heuristic detection: scope, branch type and commit type classification.
# Faithful port of the logic in modules/lib.ps1 (Get-Scope, Get-BranchScope,
# Get-BranchType, Get-CommitType, Get-GithubUsername, Remove-LiteralStrings).

import os
import re

import git_helpers as git

SCOPE_IGNORED_BRANCHES = {"main", "master", "develop", "dev", "staging", "production", "release"}
BRANCH_PREFIXES = ["feature/", "bugfix/", "hotfix/", "fix/", "chore/", "docs/", "test/", "refactor/", "perf/", "release/"]

BRANCH_TYPES = {
    "feat": "feat", "feature": "feat",
    "fix": "fix", "bugfix": "fix", "bug": "fix", "hotfix": "fix",
    "docs": "docs", "doc": "docs",
    "test": "test", "tests": "test",
    "chore": "chore",
    "refactor": "refactor", "refactoring": "refactor",
    "perf": "perf",
    "style": "style",
    "ci": "ci",
    "build": "build",
}

CONFIG_PATTERNS = [
    r"package\.json", r"package-lock\.json", r"yarn\.lock", r"pnpm-lock",
    r"tsconfig", r"jsconfig", r"webpack", r"vite\.config", r"rollup\.config",
    r"\.eslintrc", r"eslint\.config", r"\.prettierrc", r"prettier\.config",
    r"jest\.config", r"vitest\.config", r"babel\.config", r"\.babelrc",
    r"dockerfile", r"docker-compose", r"\.dockerignore",
    r"makefile", r"cmake", r"meson\.build",
    r"\.gitignore", r"\.editorconfig", r"\.env", r"\.env\.",
    r"turbo\.json", r"nx\.json", r"lerna\.json", r"pnpm-workspace",
    r"commitlint", r"husky", r"lint-staged",
    r"renovate", r"dependabot", r"\.github",
    r"netlify", r"vercel", r"firebase", r"railway", r"render",
]
CI_PATTERNS = [r"\.github/workflows", r"\.gitlab-ci", r"\.circleci", r"\.travis", r"jenkins", r"azure-pipelines", r"bitbucket-pipelines"]
DOC_PATTERNS = [r"readme", r"changelog", r"contributing", r"license", r"authors", r"docs/", r"\.md$", r"\.mdx$", r"\.rst$", r"\.txt$"]
STYLE_PATTERNS = [r"\.css$", r"\.scss$", r"\.less$", r"\.sass$", r"\.stylus$", r"\.prettierrc", r"\.stylelintrc", r"stylelint"]
DB_PATTERNS = [r"migration", r"migrate", r"schema", r"\.sql$", r"knex", r"prisma", r"sequelize", r"typeorm", r"drizzle"]
TEST_PATTERN = r"(test|spec|\.test\.|\.spec\.)"


def remove_literal_strings(content):
    if not content:
        return ""
    content = re.sub(r'"(?:[^"\\]|\\.)*"', '""', content)
    content = re.sub(r"'(?:[^'\\]|\\.)*'", "''", content)
    return content


def get_scope(files):
    if not files:
        return ""
    dir_groups = {}
    for f in files:
        parent = os.path.dirname(f)
        if parent:
            top = re.split(r"[\\/]", parent)[0]
            dir_groups[top] = dir_groups.get(top, 0) + 1
    if len(dir_groups) == 1:
        return next(iter(dir_groups))
    if len(dir_groups) > 1:
        top = max(dir_groups, key=lambda k: dir_groups[k])
        if dir_groups[top] >= len(files) * 0.6:
            return top
    if len(files) == 1:
        base = os.path.splitext(os.path.basename(files[0]))[0]
        return base
    return ""


def get_branch_scope():
    branch = git.text(["symbolic-ref", "--short", "HEAD"]).strip()
    if not branch:
        return ""
    if branch in SCOPE_IGNORED_BRANCHES:
        return ""
    if "/" in branch:
        scope = branch.split("/", 1)[1]
        for p in BRANCH_PREFIXES:
            if scope.startswith(p):
                scope = scope[len(p):]
                break
        return scope
    return ""


def get_branch_type():
    branch = git.text(["symbolic-ref", "--short", "HEAD"]).strip()
    if not branch:
        return ""
    return BRANCH_TYPES.get(branch.split("/")[0], "")


def _lines_filter(content, prefix):
    """Lines starting with prefix (e.g. '+' or '-') but not the doubled marker."""
    if not content:
        return ""
    kept = []
    for line in content.split("\n"):
        if line.startswith(prefix) and not line.startswith(prefix * 2):
            kept.append(line)
    return "\n".join(kept)


def _dedup(items):
    seen = []
    for it in items:
        if it not in seen:
            seen.append(it)
    return seen


def _unique_matches(pattern, text):
    return _dedup(re.findall(pattern, text))


def _count_matches(pattern, text):
    return len(re.findall(pattern, text))


def detect_commit_type(added, modified, deleted, added_lower, modified_lower, deleted_lower, diff_content, self_script=False):
    """Returns {'type': str, 'desc': str, 'strong': bool}."""
    if self_script:
        diff_content = remove_literal_strings(diff_content)

    all_modified = [f for f in (added_lower + modified_lower) if f]
    all_changed = [f for f in (added_lower + modified_lower + deleted_lower) if f]

    test_files = [f for f in all_modified if re.search(TEST_PATTERN, f)]
    non_test_files = [f for f in all_modified if not re.search(TEST_PATTERN, f)]

    def _match_any(files, patterns):
        return [f for f in files if any(re.search(p, f) for p in patterns)]

    is_config = _match_any(all_changed, CONFIG_PATTERNS)
    is_ci = _match_any(all_changed, CI_PATTERNS)
    is_doc = _match_any(all_changed, DOC_PATTERNS)
    is_style = _match_any(all_changed, STYLE_PATTERNS)
    is_db = _match_any(all_changed, DB_PATTERNS)
    other_files = [f for f in all_changed if not re.search(TEST_PATTERN, f) and not _match_any([f], CONFIG_PATTERNS) and not _match_any([f], CI_PATTERNS) and not _match_any([f], DOC_PATTERNS) and not _match_any([f], STYLE_PATTERNS) and not _match_any([f], DB_PATTERNS)]
    is_script = [f for f in all_changed if re.search(r"(commit-msg|\.sh$|\.ps1$|\.py$|\.rb$|\.js$|\.ts$)", f)]

    perf_content = "\n".join(l for l in diff_content.split("\n") if re.match(r"^[+-][^+-]", l))
    has_perf_content = bool(re.search(r"(perf|optim|cache|lazy|memo|defer|throttle|debounce|batch|index)", perf_content))
    has_breaking = bool(re.search(r"(BREAKING|breaking.change)", diff_content))

    added_lines = _lines_filter(diff_content, "+")
    removed_lines = _lines_filter(diff_content, "-")

    added_imports = re.findall(r"(?:import|require)\s*\{?\s*([\w]+)", added_lines)
    removed_imports = re.findall(r"(?:import|require)\s*\{?\s*([\w]+)", removed_lines)
    added_functions = re.findall(r"(?:function|const|let|var)\s+(\w+)", added_lines)
    removed_functions = re.findall(r"(?:function|const|let|var)\s+(\w+)", removed_lines)
    added_classes = re.findall(r"(?:class)\s+(\w+)", added_lines)
    removed_classes = re.findall(r"(?:class)\s+(\w+)", removed_lines)
    added_props = re.findall(r"(?:props?|interface|type)\s+(\w+)", added_lines)
    removed_props = re.findall(r"(?:props?|interface|type)\s+(\w+)", removed_lines)
    added_exports = re.findall(r"(?:export)\s+(?:default\s+)?(?:function|class|const|let|var)\s+(\w+)", added_lines)
    added_routes = re.findall(r"(?:router|Route|path)\s*\(\s*['\"]([^'\"]+)", added_lines)
    added_hooks = re.findall(r"(?:useState|useEffect|useContext|useReducer|useMemo|useCallback|useRef)\s*\(", added_lines)
    added_events = re.findall(r"(?:addEventListener|\.on\(\s*['\"])(\w+)", added_lines)
    added_async = re.findall(r"(?:async|await|Promise|\.then\()", added_lines)

    specific_parts = []

    if added_imports:
        names = ", ".join(_unique_matches(r"(?:import|require)\s*\{?\s*([\w]+)", added_lines)[:3])
        specific_parts.append("adds %s import" % names)
    if removed_imports:
        names = ", ".join(_unique_matches(r"(?:import|require)\s*\{?\s*([\w]+)", removed_lines)[:3])
        specific_parts.append("removes %s import" % names)
    if added_functions:
        names = ", ".join(_dedup(added_functions)[:2])
        specific_parts.append("adds %s" % names)
    if removed_functions:
        names = ", ".join(_dedup(removed_functions)[:2])
        specific_parts.append("removes %s" % names)
    if added_classes:
        names = ", ".join(_dedup(added_classes))
        specific_parts.append("adds %s class" % names)
    if added_props and not added_functions and not added_classes:
        names = ", ".join(_dedup(added_props)[:2])
        specific_parts.append("adds %s types" % names)
    if added_routes:
        names = ", ".join(_dedup(added_routes))
        specific_parts.append("adds %s route" % names)
    if added_hooks:
        hook_names = _first_hook_names(added_lines)
        if hook_names:
            specific_parts.append("adds %s" % hook_names)
    if added_events:
        names = ", ".join(_dedup(added_events))
        specific_parts.append("adds %s listener" % names)
    if added_async and not specific_parts:
        specific_parts.append("adds async handling")

    if not specific_parts:
        if re.search(r"console\.(log|error|warn)", added_lines):
            specific_parts.append("adds logging")
        elif re.search(r"(try|catch|throw|Error)", added_lines):
            specific_parts.append("adds error handling")
        elif re.search(r"(\/\/|#|\/\*|docs?:)", added_lines):
            specific_parts.append("adds comments")
        elif re.search(r"console\.(log|error|warn)", removed_lines):
            specific_parts.append("removes console logs")
        elif re.search(r"(className|class=|style=|className=)", added_lines):
            specific_parts.append("updates styles")
        elif re.search(r"(margin|padding|border|color|font|display|flex|grid)", added_lines):
            specific_parts.append("adjusts CSS properties")
        elif re.search(r"(width|height|size|scale|transform|position)", added_lines):
            specific_parts.append("adjusts layout")
        elif re.search(r"(onClick|onChange|onSubmit|onFocus|onBlur)", added_lines):
            specific_parts.append("adds event handlers")
        elif re.search(r"(useState|useEffect|useContext|useReducer)", added_lines):
            specific_parts.append("adds React hooks")
        elif re.search(r"(fetch|axios|http|api|endpoint)", added_lines):
            specific_parts.append("adds API call")
        elif re.search(r"(if|else|switch|case|return)", added_lines):
            specific_parts.append("updates logic")

    specific_desc = " and ".join(specific_parts)

    def _name(f):
        return os.path.basename(f)

    def _base(f):
        return os.path.splitext(os.path.basename(f))[0]

    def _ext(f):
        return os.path.splitext(f)[1].lower()

    if deleted and not added and not modified:
        deleted_is_doc = [f for f in deleted if re.search(r"\.(md|mdx|rst|txt)$|readme|changelog|docs/", f)]
        if len(deleted_is_doc) == len(deleted):
            if len(deleted) == 1:
                return {"type": "docs", "desc": "removes %s" % _name(deleted[0]), "strong": True}
            return {"type": "docs", "desc": "removes %d documentation files" % len(deleted), "strong": True}
        if len(deleted) == 1:
            if specific_desc:
                return {"type": "refactor", "desc": "%s from %s" % (specific_desc, _name(deleted[0])), "strong": False}
            return {"type": "refactor", "desc": "removes %s" % _name(deleted[0]), "strong": False}
        return {"type": "refactor", "desc": "removes %d files" % len(deleted), "strong": False}

    if is_config and not other_files and not is_doc and not is_ci:
        if any(re.search(r"package\.json|yarn\.lock|pnpm-lock|npm", f) for f in is_config):
            pkg_changes = re.findall(r'"([\w@/-]+)"\s*:\s*"', diff_content)
            pkgs = [p for p in _dedup(pkg_changes) if not re.search(r"^(name|version|description|main|scripts|dependencies|devDependencies)", p)][:3]
            if pkgs:
                return {"type": "build", "desc": "updates %s dependency" % ", ".join(pkgs), "strong": True}
            return {"type": "build", "desc": "updates dependencies", "strong": True}
        if any(re.search(r"dockerfile|docker-compose", f) for f in is_config):
            return {"type": "build", "desc": "updates Docker configuration", "strong": True}
        return {"type": "chore", "desc": "updates configuration", "strong": True}

    if is_ci and not other_files:
        return {"type": "ci", "desc": "updates CI pipeline", "strong": True}

    if is_doc and not non_test_files and not is_config:
        if specific_desc:
            return {"type": "docs", "desc": specific_desc, "strong": True}
        return {"type": "docs", "desc": "updates documentation", "strong": True}

    if test_files and not non_test_files:
        if added and not modified:
            if len(test_files) == 1:
                test_name = _base(added[0])
                if re.search(r"(describe|it|test)\s*\(", added_lines):
                    test_names = _unique_matches(r"(?:describe|it|test)\s*\(\s*['\"]([^'\"]+)", added_lines)[:2]
                    if test_names:
                        return {"type": "test", "desc": "adds %s test for %s" % (", ".join(test_names), test_name), "strong": True}
                return {"type": "test", "desc": "adds tests for %s" % test_name, "strong": True}
            return {"type": "test", "desc": "adds %d test files" % len(test_files), "strong": True}
        if specific_desc:
            return {"type": "test", "desc": specific_desc, "strong": True}
        return {"type": "test", "desc": "updates tests", "strong": True}

    if is_style and not non_test_files:
        if specific_desc:
            return {"type": "style", "desc": specific_desc, "strong": True}
        return {"type": "style", "desc": "fixes formatting", "strong": True}

    if is_db and not other_files:
        if added and not modified:
            table_names = _unique_matches(r"(?:CREATE TABLE|ALTER TABLE|INSERT INTO)\s+(\w+)", diff_content)
            if table_names:
                return {"type": "feat", "desc": "adds migration for %s" % ", ".join(table_names), "strong": True}
            return {"type": "feat", "desc": "adds database migration", "strong": True}
        return {"type": "fix", "desc": "fixes database schema", "strong": True}

    if has_perf_content and not added and not is_doc and not is_config and not test_files and not is_style and not is_script:
        perf_items = _unique_matches(r"(cache|memo|lazy|defer|throttle|debounce|batch|index|optim)", perf_content)[:2]
        if perf_items:
            return {"type": "perf", "desc": "adds %s optimization" % ", ".join(perf_items), "strong": True}
        return {"type": "perf", "desc": "improves performance", "strong": True}

    if added and not modified and not deleted:
        if len(added) == 1:
            f = added[0]
            if re.search(r"\.(css|scss|less|sass|styled)", _ext(f)):
                return {"type": "style", "desc": "adds styles for %s" % _base(f), "strong": True}
            if re.search(r"\.(md|mdx|rst|txt)", _ext(f)):
                return {"type": "docs", "desc": "adds %s" % _name(f), "strong": True}
            if specific_desc:
                return {"type": "feat", "desc": "%s in %s" % (specific_desc, _base(f)), "strong": False}
            return {"type": "feat", "desc": "adds %s" % _name(f), "strong": False}
        return {"type": "feat", "desc": "adds %d files" % len(added), "strong": False}

    if not added and modified and not deleted:
        if len(modified) == 1:
            f = modified[0]
            if re.search(r"\.(md|mdx|rst|txt)", _ext(f)):
                return {"type": "docs", "desc": "updates %s" % _name(f), "strong": True}
            if re.search(r"\.(css|scss|less|sass)", _ext(f)):
                if specific_desc:
                    return {"type": "style", "desc": "%s in %s" % (specific_desc, _base(f)), "strong": True}
                return {"type": "style", "desc": "fixes styles in %s" % _base(f), "strong": True}
            if specific_desc:
                return {"type": "fix", "desc": "%s in %s" % (specific_desc, _base(f)), "strong": False}
            return {"type": "fix", "desc": "fixes %s" % _name(f), "strong": False}
        if specific_desc:
            if specific_desc.startswith("adds "):
                return {"type": "feat", "desc": specific_desc, "strong": False}
            if specific_desc.startswith("removes "):
                return {"type": "refactor", "desc": specific_desc, "strong": False}
            return {"type": "fix", "desc": specific_desc, "strong": False}
        return {"type": "fix", "desc": "updates %d files" % len(modified), "strong": False}

    if specific_desc and specific_desc.startswith("adds "):
        return {"type": "feat", "desc": specific_desc, "strong": False}
    if specific_desc:
        return {"type": "refactor", "desc": specific_desc, "strong": False}
    parts = []
    if added:
        parts.append("%d added" % len(added))
    if modified:
        parts.append("%d modified" % len(modified))
    if deleted:
        parts.append("%d removed" % len(deleted))
    return {"type": "refactor", "desc": ", ".join(parts), "strong": False}


def _first_hook_names(added_lines):
    """First `name(` match per line, filtered to `use*`, unique, max 3 (PS Select-String)."""
    names = []
    for line in added_lines.split("\n"):
        m = re.search(r"(\w+)\s*\(", line)
        if m and m.group(1).startswith("use") and m.group(1) not in names:
            names.append(m.group(1))
        if len(names) >= 3:
            break
    return ", ".join(names)


def get_github_username(name, email):
    m = re.match(r"^([^@+]+)(\+[^@]*)?@users\.noreply\.github\.com$", email)
    if m and re.match(r"^[a-zA-Z0-9-]+$", m.group(1)):
        return m.group(1)
    if re.match(r"^@([a-zA-Z0-9-]+)$", name):
        return re.match(r"^@([a-zA-Z0-9-]+)$", name).group(1)
    if re.match(r"^[a-zA-Z0-9-]+$", name):
        return name
    return ""
