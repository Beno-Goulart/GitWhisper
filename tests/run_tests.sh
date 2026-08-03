#!/usr/bin/env bash
#
# GitWhisper automated test suite.
#
# Covers: message generation (suggest), config parsing, `init` behavior,
# hook behavior, the interactive `commit` flow, and parity of commit-type
# classification between gitwhisper.ps1 and gitwhisper.sh.
#
# Usage:
#   bash tests/run_tests.sh                      # all core tests
#   GW_TEST_COMMITS=1 bash tests/run_tests.sh    # also commit-dependent tests
#
# Exit code: 0 = all passed, 1 = at least one failure.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$ROOT/gitwhisper.sh"
PS1="$ROOT/gitwhisper.ps1"

PASS=0
FAIL=0
TMP="$(mktemp -d 2>/dev/null || echo "/tmp/gwtest-$$")"
REPO_COUNTER=0

trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() {
    FAIL=$((FAIL + 1))
    echo "FAIL  $1"
    shift
    for line in "$@"; do
        echo "       $line"
    done
}

check_exit() { # name want_exit got_exit
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want exit $2, got $3"; fi
}

check_contains() { # name needle haystack
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "missing: [$2]" "output: [$(printf '%s\n' "$3" | head -6)]" ;;
    esac
}

check_not_contains() { # name needle haystack
    case "$3" in
        *"$2"*) fail "$1" "unexpectedly present: [$2]" ;;
        *) pass "$1" ;;
    esac
}

# run_sh [stdin] args... -- run gitwhisper.sh, capturing RUN_OUT / RUN_EXIT
run_sh() {
    local stdin_data="${1:-}"
    shift
    RUN_OUT=$(printf '%s\n' "$stdin_data" | bash "$SH" "$@" 2>&1)
    RUN_EXIT=$?
}

run_ps1() {
    local stdin_data="${1:-}"
    shift
    local ps_cmd="powershell.exe"
    if ! command -v powershell.exe >/dev/null 2>&1; then
        ps_cmd="pwsh"
    fi
    local win="$PS1"
    if command -v cygpath >/dev/null 2>&1; then
        win=$(cygpath -m "$PS1")
    fi
    RUN_OUT=$(printf '%s\n' "$stdin_data" | "$ps_cmd" -NoProfile -ExecutionPolicy Bypass -File "$win" "$@" 2>&1)
    RUN_EXIT=$?
}

new_repo() {
    REPO_COUNTER=$((REPO_COUNTER + 1))
    REPO="$TMP/repo$REPO_COUNTER"
    git init -q "$REPO"
    git -C "$REPO" config user.email "test@example.com"
    git -C "$REPO" config user.name "Test"
    git -C "$REPO" config commit.gpgsign false
    cd "$REPO" || return 1
}

add_file() { # path content
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
    git add "$1"
}

# make_baseline file... -- create HEAD containing the given files without `git commit`
make_baseline() {
    git add "$@"
    local tree commit
    tree=$(git write-tree)
    commit=$(echo baseline | git commit-tree "$tree")
    git update-ref HEAD "$commit"
    git reset -q
}

HAVE_PS1=false
if [ -f "$PS1" ] && { command -v powershell.exe >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; }; then
    HAVE_PS1=true
fi

#
# help / commands
#
test_help() {
    new_repo
    run_sh "" help
    check_exit "help exits 0" 0 "$RUN_EXIT"
    check_contains "help lists init" "gitwhisper init" "$RUN_OUT"
    check_contains "help lists suggest" "gitwhisper suggest" "$RUN_OUT"
    check_contains "help lists undo" "gitwhisper undo" "$RUN_OUT"

    run_sh "" bogus
    check_contains "unknown command shows message" "Unknown command" "$RUN_OUT"
}

test_undo_empty() {
    new_repo
    run_sh "" undo
    check_exit "undo with no commits exits 0" 0 "$RUN_EXIT"
    check_contains "undo with no commits says nothing to undo" "Nothing to undo" "$RUN_OUT"
}

#
# suggest / message generation
#
test_suggest_basics() {
    new_repo
    add_file "app.js" "console.log(1)"
    run_sh "" suggest
    check_exit "suggest exits 0" 0 "$RUN_EXIT"
    check_contains "single added js -> feat" "feat" "$RUN_OUT"
    check_contains "single added js -> emoji on by default" "✨" "$RUN_OUT"
    check_contains "single added js -> body has Added section" "Added:" "$RUN_OUT"
    check_contains "single added js -> body lists file" "- app.js" "$RUN_OUT"
    check_contains "single added js -> Change summary" "Change summary" "$RUN_OUT"
}

test_suggest_scopes_and_types() {
    new_repo
    add_file "src/app.js" "console.log(1)"
    run_sh "" suggest
    check_contains "subdir file -> scope" "feat(src)" "$RUN_OUT"

    new_repo
    add_file "README.md" "# docs"
    run_sh "" suggest
    check_contains "added md -> docs type" "docs" "$RUN_OUT"

    new_repo
    add_file "style.css" "body {}"
    run_sh "" suggest
    check_contains "added css -> style type" "style" "$RUN_OUT"

    new_repo
    add_file "app.test.js" "test()"
    run_sh "" suggest
    check_contains "test file -> test type" "test" "$RUN_OUT"

    new_repo
    add_file "package.json" "{}"
    run_sh "" suggest
    check_contains "config file -> build type" "build" "$RUN_OUT"

    new_repo
    add_file ".github/workflows/ci.yml" "on: push"
    run_sh "" suggest
    check_contains "ci file -> ci type" "ci" "$RUN_OUT"

    new_repo
    add_file "src/migrations/001_users.sql" "CREATE TABLE users (id INT PRIMARY KEY);"
    run_sh "" suggest
    check_contains "migration file -> feat type" "feat(src)" "$RUN_OUT"
    check_contains "migration file -> migration desc" "adds migration for users" "$RUN_OUT"

    new_repo
    add_file "src/migrations/001_users.sql" "base"
    make_baseline src/migrations/001_users.sql
    printf 'CREATE TABLE users (id INT PRIMARY KEY, email TEXT);\n' > src/migrations/001_users.sql
    git add src/migrations/001_users.sql
    run_sh "" suggest
    check_contains "modified migration -> fix type" "fix(src)" "$RUN_OUT"

    new_repo
    echo "base-app" > app.js
    make_baseline app.js
    printf 'x2\n' > app.js
    git add app.js
    run_sh "" suggest
    check_contains "modified js -> fix type" "fix" "$RUN_OUT"

    new_repo
    echo "base-legacy" > legacy.js
    echo "base-app" > app.js
    make_baseline legacy.js app.js
    git rm -q legacy.js
    run_sh "" suggest
    check_contains "deleted file -> refactor type" "refactor" "$RUN_OUT"
    check_contains "deleted file -> removes legacy.js" "removes legacy.js" "$RUN_OUT"
}

test_suggest_multiple_and_empty() {
    new_repo
    add_file "a.js" "1"
    add_file "b.js" "2"
    add_file "c.js" "3"
    run_sh "" suggest
    check_contains "multiple added -> count" "adds 3 files" "$RUN_OUT"

    new_repo
    run_sh "" suggest
    check_exit "no staged changes -> exit 0" 0 "$RUN_EXIT"
    if [ -z "$RUN_OUT" ]; then
        pass "no staged changes -> no output"
    else
        fail "no staged changes -> no output" "got: [$(printf '%s\n' "$RUN_OUT" | head -3)]"
    fi
}

test_suggest_branch_type() {
    new_repo
    echo "base" > login.js
    git add login.js
    make_baseline login.js
    git checkout -b feat/login
    printf 'x2\n' > login.js
    git add login.js
    run_sh "" suggest
    check_contains "branch feat overrides fix" "feat(login)" "$RUN_OUT"
    check_not_contains "branch feat not fix" "fix(login)" "$RUN_OUT"

    new_repo
    git checkout -b fix/button
    add_file "button.js" "function btn(){}"
    run_sh "" suggest
    check_contains "branch fix overrides feat" "fix(button)" "$RUN_OUT"

    new_repo
    git checkout -b feat/login
    add_file "README.md" "# hi"
    run_sh "" suggest
    check_contains "strong docs not overridden by feat branch" "docs" "$RUN_OUT"
    check_not_contains "docs branch keeps docs type" "feat(" "$RUN_OUT"

    new_repo
    git checkout -b fix/login
    add_file "app.test.js" "test()"
    run_sh "" suggest
    check_contains "strong test not overridden by fix branch" "test" "$RUN_OUT"

    new_repo
    echo "a" > a.js
    echo "b" > b.js
    git add a.js b.js
    make_baseline a.js b.js
    git checkout -b chore/core
    printf 'x\n' > a.js
    printf 'y\n' > b.js
    git add a.js b.js
    run_sh "" suggest
    check_contains "branch chore overrides refactor" "chore(core)" "$RUN_OUT"

    new_repo
    echo "x" > app.js
    git add app.js
    make_baseline app.js
    git checkout -b login
    printf 'x2\n' > app.js
    git add app.js
    run_sh "" suggest
    check_contains "branch without prefix keeps diff fix" "fix(app)" "$RUN_OUT"
}

#
# type refinement: avoid the over-use of `refactor` (multi-file modified,
# deletions of docs, and feature-like mixed changes)
#
test_suggest_type_refinement() {
    new_repo
    echo "a1" > a.js
    echo "b1" > b.js
    echo "c1" > c.js
    git add a.js b.js c.js
    make_baseline a.js b.js c.js
    printf 'a2\n' > a.js
    printf 'b2\n' > b.js
    printf 'c2\n' > c.js
    git add a.js b.js c.js
    run_sh "" suggest
    check_contains "modified multiple js -> fix" "fix" "$RUN_OUT"
    check_not_contains "modified multiple js -> not refactor" "refactor" "$RUN_OUT"
    check_contains "modified multiple js -> updates" "updates" "$RUN_OUT"
    run_ps1 "" suggest
    check_contains "ps1 modified multiple js -> fix" "fix" "$RUN_OUT"
    check_not_contains "ps1 modified multiple js -> not refactor" "refactor" "$RUN_OUT"

    new_repo
    echo "base1" > a.js
    echo "base2" > b.js
    git add a.js b.js
    make_baseline a.js b.js
    printf 'function newHelper() { return 1; }\n' >> a.js
    printf 'const other = newHelper();\n' >> b.js
    git add a.js b.js
    run_sh "" suggest
    check_contains "modified multiple js with added fn -> feat" "feat" "$RUN_OUT"
    check_not_contains "modified multiple js with added fn -> not refactor" "refactor" "$RUN_OUT"
    run_ps1 "" suggest
    check_contains "ps1 modified multiple js with added fn -> feat" "feat" "$RUN_OUT"
    check_not_contains "ps1 modified multiple js with added fn -> not refactor" "refactor" "$RUN_OUT"

    new_repo
    echo "a1" > a.js
    echo "b1" > b.js
    git add a.js b.js
    make_baseline a.js b.js
    printf 'function added() {}\n' > c.js
    git add c.js
    printf 'x\n' >> a.js
    git add a.js
    run_sh "" suggest
    check_contains "mixed add+modify with added fn -> feat" "feat" "$RUN_OUT"
    check_not_contains "mixed add+modify with added fn -> not refactor" "refactor" "$RUN_OUT"
    run_ps1 "" suggest
    check_contains "ps1 mixed add+modify with added fn -> feat" "feat" "$RUN_OUT"
    check_not_contains "ps1 mixed add+modify with added fn -> not refactor" "refactor" "$RUN_OUT"

    new_repo
    mkdir -p docs
    echo "readme-content" > README.md
    echo "other-content" > docs/guide.md
    git add README.md docs/guide.md
    make_baseline README.md docs/guide.md
    git rm -q README.md docs/guide.md
    run_sh "" suggest
    check_contains "deleted docs -> docs type" "docs" "$RUN_OUT"
    check_not_contains "deleted docs -> not refactor" "refactor" "$RUN_OUT"
    run_ps1 "" suggest
    check_contains "ps1 deleted docs -> docs type" "docs" "$RUN_OUT"
    check_not_contains "ps1 deleted docs -> not refactor" "refactor" "$RUN_OUT"

    new_repo
    echo "readme-content" > README.md
    git add README.md
    make_baseline README.md
    git rm -q README.md
    run_sh "" suggest
    check_contains "deleted single doc -> removes README.md" "removes README.md" "$RUN_OUT"
}

test_suggest_config() {
    new_repo
    add_file "app.js" "console.log(1)"

    cat > .gitwhisperconfig <<'EOF'
[general]
emoji = false
default = 2
EOF
    run_sh "" suggest
    check_not_contains "emoji=false -> no sparkle" "✨" "$RUN_OUT"
    check_contains "default=2 -> no emoji in title" "feat(app):" "$RUN_OUT"

    sed -i 's/default = 2/default = 3/' .gitwhisperconfig
    run_sh "" suggest
    check_contains "default=3 -> detailed title" "updates scripts (app)" "$RUN_OUT"

    sed -i 's/default = 3/default = 4/' .gitwhisperconfig
    run_sh "" suggest
    check_not_contains "default=4 -> no emoji" "✨" "$RUN_OUT"
    check_contains "default=4 -> detailed without emoji" "feat(app): updates scripts (app)" "$RUN_OUT"

    cat > .gitwhisperconfig <<'EOF'
[general]
default = 99
EOF
    run_sh "" suggest
    check_contains "invalid default -> falls back to 1" "✨" "$RUN_OUT"
}

#
# custom .gitwhisperconfig: [types] emoji/title/order, [scope] map, forced scope
#
test_custom_config() {
    new_repo
    add_file "app.js" "console.log(1)"

    cat > .gitwhisperconfig <<'EOF'
[general]
default = 1
[types]
feat = 🚀|🚀 Features
EOF
    run_sh "" suggest
    check_contains "custom feat emoji used" "🚀 feat(app):" "$RUN_OUT"
    check_not_contains "default feat emoji not used" "✨" "$RUN_OUT"
    if [ "$HAVE_PS1" = true ]; then
        run_ps1 "" suggest
        check_contains "ps1 custom feat emoji used" "🚀 feat(app):" "$RUN_OUT"
        check_not_contains "ps1 default feat emoji not used" "✨" "$RUN_OUT"
    fi

    new_repo
    add_file "app.js" "console.log(1)"
    printf '[general]\nscope = core\n' > .gitwhisperconfig
    run_sh "" suggest
    check_contains "forced scope applied" "feat(core):" "$RUN_OUT"
    if [ "$HAVE_PS1" = true ]; then
        run_ps1 "" suggest
        check_contains "ps1 forced scope applied" "feat(core):" "$RUN_OUT"
    fi

    new_repo
    mkdir -p src
    add_file "src/thing.js" "x"
    printf '[scope]\nsrc = api\n' > .gitwhisperconfig
    run_sh "" suggest
    check_contains "scope map dir -> scope" "feat(api):" "$RUN_OUT"
    if [ "$HAVE_PS1" = true ]; then
        run_ps1 "" suggest
        check_contains "ps1 scope map dir -> scope" "feat(api):" "$RUN_OUT"
    fi

    new_repo
    printf '[types]\nsecurity = x|Security\n' > .gitwhisperconfig
    run_sh "" init >/dev/null 2>&1
    printf 'security: harden auth\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg accepts custom type from [types]" 0 "$?"
    printf 'nope: random\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg still rejects unknown type" 1 "$?"
    printf 'feat: still works\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg still accepts default type" 0 "$?"
}

#
# init
#
test_init_creates_files() {
    new_repo
    run_sh "" init
    check_exit "init exits 0" 0 "$RUN_EXIT"
    [ -f .gitwhisperconfig ] && pass "init creates .gitwhisperconfig" || fail "init creates .gitwhisperconfig"
    [ -f .git/hooks/prepare-commit-msg ] && pass "init installs prepare-commit-msg" || fail "init installs prepare-commit-msg"
    [ -f .git/hooks/commit-msg ] && pass "init installs commit-msg" || fail "init installs commit-msg"

    check_contains "config has emoji key" "emoji = true" "$(cat .gitwhisperconfig)"
    check_contains "config has default key" "default = 1" "$(cat .gitwhisperconfig)"
    check_contains "prepare hook is from GitWhisper" "GitWhisper init" "$(cat .git/hooks/prepare-commit-msg)"
    check_contains "commit-msg hook is from GitWhisper" "GitWhisper init" "$(cat .git/hooks/commit-msg)"

    local gw_cmd
    gw_cmd=$(sed -n 's/^GW_CMD="\(.*\)"$/\1/p' .git/hooks/prepare-commit-msg)
    if [ -n "$gw_cmd" ]; then pass "prepare hook has GW_CMD"; else fail "prepare hook has GW_CMD"; fi

    run_sh "" init
    check_contains "re-init keeps existing config" "Keeping it" "$RUN_OUT"
}

test_init_force_and_backup() {
    new_repo
    printf '#!/bin/sh\necho custom hook\n' > .git/hooks/commit-msg
    run_sh "" init --force
    check_exit "init --force exits 0" 0 "$RUN_EXIT"
    [ -f .git/hooks/commit-msg.bak ] && pass "--force backs up existing hook" || fail "--force backs up existing hook"
    check_contains "--force overwrites with GitWhisper hook" "GitWhisper" "$(cat .git/hooks/commit-msg)"
    check_contains "backup keeps original content" "custom hook" "$(cat .git/hooks/commit-msg.bak)"

    new_repo
    printf '#!/bin/sh\necho custom2\n' > .git/hooks/commit-msg
    run_sh "n" init
    check_contains "answer 'n' keeps custom hook" "custom2" "$(cat .git/hooks/commit-msg)"
    [ ! -f .git/hooks/commit-msg.bak ] && pass "answer 'n' -> no backup" || fail "answer 'n' -> no backup"

    new_repo
    printf '#!/bin/sh\necho custom3\n' > .git/hooks/commit-msg
    run_sh "y" init
    check_contains "answer 'y' overwrites hook" "GitWhisper" "$(cat .git/hooks/commit-msg)"
    [ -f .git/hooks/commit-msg.bak ] && pass "answer 'y' -> backup created" || fail "answer 'y' -> backup created"
}

test_init_hook_toggles() {
    new_repo
    printf '[hooks]\nprepare = false\nvalidate = true\n' > .gitwhisperconfig
    run_sh "" init
    [ ! -f .git/hooks/prepare-commit-msg ] && pass "hooks.prepare=false removes prepare hook" || fail "hooks.prepare=false removes prepare hook"
    [ -f .git/hooks/commit-msg ] && pass "hooks.validate=true keeps commit-msg hook" || fail "hooks.validate=true keeps commit-msg hook"

    new_repo
    printf '[hooks]\nprepare = true\nvalidate = false\n' > .gitwhisperconfig
    run_sh "" init
    [ -f .git/hooks/prepare-commit-msg ] && pass "hooks.prepare=true installs prepare hook" || fail "hooks.prepare=true installs prepare hook"
    [ ! -f .git/hooks/commit-msg ] && pass "hooks.validate=false removes commit-msg hook" || fail "hooks.validate=false removes commit-msg hook"
}

#
# hook behavior
#
test_prepare_hook() {
    new_repo
    add_file "app.js" "console.log(1)"
    run_sh "" init >/dev/null 2>&1

    local suggest_out file_out
    suggest_out=$(bash "$SH" suggest)

    printf '# template comment\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/prepare-commit-msg .git/COMMIT_EDITMSG "" >/dev/null 2>&1
    file_out=$(cat .git/COMMIT_EDITMSG)
    check_contains "prepare hook pre-fills message" "feat" "$file_out"
    if [ "$file_out" = "$suggest_out" ]; then
        pass "pre-filled equals suggest output"
    else
        fail "pre-filled equals suggest output" "hook:  [$file_out]" "suggest: [$suggest_out]"
    fi

    printf '# template\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/prepare-commit-msg .git/COMMIT_EDITMSG "message" >/dev/null 2>&1
    file_out=$(cat .git/COMMIT_EDITMSG)
    check_not_contains "prepare hook skips source=message" "feat" "$file_out"

    printf 'feat: keep this\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/prepare-commit-msg .git/COMMIT_EDITMSG "" >/dev/null 2>&1
    file_out=$(cat .git/COMMIT_EDITMSG)
    check_contains "prepare hook does not overwrite real content" "keep this" "$file_out"
}

test_commit_msg_hook() {
    new_repo
    run_sh "" init >/dev/null 2>&1

    printf 'feat: add login\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg accepts basic feat" 0 "$?"

    printf 'feat(api): add login endpoint\n\nBody here\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg accepts scoped feat" 0 "$?"

    printf '✨ feat: adds app.js\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg accepts emoji prefix" 0 "$?"

    printf 'fix: resolve crash' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg accepts message without trailing newline" 0 "$?"

    printf '  feat: padded subject\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg accepts leading whitespace" 0 "$?"

    printf 'some random text\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg rejects non-conventional" 1 "$?"

    printf '# only comments\n' > .git/COMMIT_EDITMSG
    bash .git/hooks/commit-msg .git/COMMIT_EDITMSG >/dev/null 2>&1
    check_exit "commit-msg rejects comments-only" 1 "$?"
}

#
# interactive commit flow (dry-run, guards the prepare_message refactor)
#
test_interactive_commit() {
    new_repo
    add_file "app.js" "console.log(1)"

    RUN_OUT=$(printf '1\n' | bash "$SH" --dry-run 2>&1)
    RUN_EXIT=$?
    check_exit "interactive commit dry-run exits 0" 0 "$RUN_EXIT"
    check_contains "interactive shows message choice" "Choose your commit message" "$RUN_OUT"
    check_contains "interactive shows option 1" "[1]" "$RUN_OUT"
    check_contains "interactive shows feat suggestion" "feat" "$RUN_OUT"
    check_contains "interactive dry-run prints Committing" "Committing:" "$RUN_OUT"
    check_contains "interactive dry-run skips commit" "DRY-RUN" "$RUN_OUT"

    RUN_OUT=$(printf '2\n' | bash "$SH" --dry-run 2>&1)
    check_contains "option 2 selected -> no emoji" "Committing: feat" "$RUN_OUT"
    local committing_line
    committing_line=$(printf '%s\n' "$RUN_OUT" | grep "Committing:" | head -1)
    check_not_contains "option 2 selected -> no sparkle" "✨" "$committing_line"
}

#
# parity: commit type + scope classification ps1 vs sh
#
extract_type() { # suggest output -> type(scope)
    local first
    first=$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | head -1)
    first=$(printf '%s' "$first" | tr -d '\200-\377')
    first=$(printf '%s' "$first" | sed 's/^[[:space:]]*//')
    printf '%s' "$first" | grep -oE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert|db)(\([^)]*\))?'
}

test_parity() { # name  (current repo must have staged changes)
    local name="$1"
    if [ "$HAVE_PS1" = false ]; then
        pass "parity: $name (skipped, powershell not available)"
        return
    fi
    run_sh "" suggest
    local sh_out="$RUN_OUT"
    run_ps1 "" suggest
    local ps1_out="$RUN_OUT"

    local sh_type ps1_type
    sh_type=$(extract_type "$sh_out")
    ps1_type=$(extract_type "$ps1_out")

    if [ -n "$sh_type" ] && [ "$sh_type" = "$ps1_type" ]; then
        pass "parity: $name ($sh_type)"
    else
        fail "parity: $name" "sh:  [$sh_type]" "ps1: [$ps1_type]" "sh line:  [$(printf '%s\n' "$sh_out" | head -1)]" "ps1 line: [$(printf '%s\n' "$ps1_out" | head -1)]"
    fi
}

test_parity_cases() {
    new_repo
    add_file "app.js" "console.log(1)"
    test_parity "added single js"

    new_repo
    add_file "README.md" "# docs"
    test_parity "added single md"

    new_repo
    add_file "src/app.js" "console.log(1)"
    test_parity "added scoped js"

    new_repo
    add_file "a.js" "1"
    add_file "b.js" "2"
    test_parity "added multiple js"

    new_repo
    add_file "app.js" "x"
    echo "base" > app.js
    make_baseline app.js
    printf 'x2\n' > app.js
    git add app.js
    test_parity "modified single js"

    new_repo
    echo "base" > legacy.js
    make_baseline legacy.js
    git rm -q legacy.js
    test_parity "deleted single js"

    new_repo
    add_file "style.css" "body {}"
    test_parity "added css"

    new_repo
    add_file "app.test.js" "test()"
    test_parity "added test file"

    new_repo
    add_file "package.json" "{}"
    test_parity "added config"

    new_repo
    add_file ".github/workflows/ci.yml" "on: push"
    test_parity "added ci file"

    new_repo
    add_file "src/migrations/001_users.sql" "CREATE TABLE users (id INT PRIMARY KEY);"
    test_parity "added migration sql"

    new_repo
    add_file "src/migrations/001_users.sql" "base"
    make_baseline src/migrations/001_users.sql
    printf 'CREATE TABLE users (id INT PRIMARY KEY, email TEXT);\n' > src/migrations/001_users.sql
    git add src/migrations/001_users.sql
    test_parity "modified migration sql"

    new_repo
    cp "$SH" ./gitwhisper.sh
    git add gitwhisper.sh
    make_baseline gitwhisper.sh
    printf '\necho "noise feat perf docs"\n' >> gitwhisper.sh
    git add gitwhisper.sh
    test_parity "modified self sh"

    new_repo
    cp "$PS1" ./gitwhisper.ps1
    git add gitwhisper.ps1
    make_baseline gitwhisper.ps1
    printf '\nWrite-Host "noise feat perf docs"\n' >> gitwhisper.ps1
    git add gitwhisper.ps1
    test_parity "modified self ps1"

    new_repo
    echo "base" > login.js
    git add login.js
    make_baseline login.js
    git checkout -b feat/login
    printf 'x2\n' > login.js
    git add login.js
    test_parity "branch feat overrides fix"

    new_repo
    git checkout -b fix/button
    add_file "button.js" "function btn(){}"
    test_parity "branch fix overrides feat"

    new_repo
    git checkout -b feat/login
    add_file "README.md" "# hi"
    test_parity "branch feat keeps strong docs"
}

#
# self-script noise: when the diff touches gitwhisper.* / install.*, literal
# strings inside the script must be ignored so they do not pollute the message.
#
test_self_script_noise() {
    new_repo
    cp "$SH" ./gitwhisper.sh
    git add gitwhisper.sh
    make_baseline gitwhisper.sh
    cat >> gitwhisper.sh <<'NOISE'

# comment with perf cache index memo throttle debounce batch optim
echo "literal string with feat fix docs build ci style refactor perf"
echo 'another literal: test chore revert db schema migration package.json'
GITMOJI[perf]="x"
NOISE
    git add gitwhisper.sh
    run_sh "" suggest
    check_contains "self-script edit -> fix type" "fix" "$RUN_OUT"
    check_contains "self-script edit -> gitwhisper scope" "gitwhisper" "$RUN_OUT"
    check_not_contains "self-script edit -> no perf noise" "perf" "$RUN_OUT"

    new_repo
    cp "$PS1" ./gitwhisper.ps1
    git add gitwhisper.ps1
    make_baseline gitwhisper.ps1
    cat >> gitwhisper.ps1 <<'NOISE'

# comment with perf cache index memo throttle debounce batch optim
Write-Host "literal string with feat fix docs build ci style refactor perf"
$msg = 'another literal: test chore revert db schema migration package.json'
NOISE
    git add gitwhisper.ps1
    run_sh "" suggest
    check_contains "self-ps1 edit -> fix type" "fix" "$RUN_OUT"
    check_contains "self-ps1 edit -> gitwhisper scope" "gitwhisper" "$RUN_OUT"
    check_not_contains "self-ps1 edit -> no perf noise" "perf" "$RUN_OUT"
}

#
# installers (install.sh / install.ps1)
#
test_installers() {
    INST_SH="$ROOT/install.sh"
    INST_PS1="$ROOT/install.ps1"

    # ---- sh: check mode ----
    bash "$INST_SH" --check --profile "$TMP/install_check_prof" >/dev/null 2>&1
    check_exit "sh --check exits 0" 0 "$?"

    # ---- sh: batch function install ----
    SH_PROF="$TMP/install_sh_prof"
    SH_BIN="$TMP/install_sh_bin"
    bash "$INST_SH" --yes --profile "$SH_PROF" >/dev/null 2>&1
    check_exit "sh install function exits 0" 0 "$?"
    [ -f "$SH_PROF" ] && grep -q "# >>> GitWhisper >>>" "$SH_PROF" \
        && pass "sh install appends marker block" \
        || fail "sh install appends marker block"
    grep -q "gitwhisper()" "$SH_PROF" && pass "sh install adds function" || fail "sh install adds function"

    # ---- sh: idempotent reinstall ----
    bash "$INST_SH" --yes --profile "$SH_PROF" >/dev/null 2>&1
    markers=$(grep -c "# >>> GitWhisper >>>" "$SH_PROF")
    [ "$markers" = "1" ] && pass "sh reinstall keeps one block" || fail "sh reinstall keeps one block" "markers=$markers"

    # ---- sh: bin type ----
    bash "$INST_SH" --yes --profile "$SH_PROF" --type bin --bin-dir "$SH_BIN" >/dev/null 2>&1
    check_exit "sh install bin exits 0" 0 "$?"
    [ -x "$SH_BIN/gitwhisper" ] && pass "sh bin wrapper created + executable" || fail "sh bin wrapper created + executable"
    grep -q "export PATH=\"$SH_BIN" "$SH_PROF" && pass "sh bin adds PATH export" || fail "sh bin adds PATH export"

    # ---- sh: uninstall ----
    bash "$INST_SH" --uninstall --profile "$SH_PROF" >/dev/null 2>&1
    check_exit "sh uninstall exits 0" 0 "$?"
    grep -q "# >>> GitWhisper >>>" "$SH_PROF" && fail "sh uninstall removes block" || pass "sh uninstall removes block"
    [ -e "$SH_BIN/gitwhisper" ] && fail "sh uninstall removes wrapper" || pass "sh uninstall removes wrapper"

    # ---- sh: interactive wizard - change profile option then install ----
    WIZ_PROF1="$TMP/install_wiz1"
    WIZ_PROF2="$TMP/install_wiz2"
    printf '2\n1\n%s\ni\n5\n' "$WIZ_PROF2" | bash "$INST_SH" --profile "$WIZ_PROF1" >/dev/null 2>&1
    check_exit "sh wizard (edit options + install) exits 0" 0 "$?"
    [ -f "$WIZ_PROF2" ] && grep -q "# >>> GitWhisper >>>" "$WIZ_PROF2" \
        && pass "sh wizard installs into edited profile" \
        || fail "sh wizard installs into edited profile"

    # ---- ps1: batch install + uninstall ----
    if command -v powershell.exe >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then
        local ps_cmd="powershell.exe"
        if ! command -v powershell.exe >/dev/null 2>&1; then
            ps_cmd="pwsh"
        fi
        local inst_ps1_win="$INST_PS1"
        if command -v cygpath >/dev/null 2>&1; then
            inst_ps1_win=$(cygpath -m "$INST_PS1")
        fi
        PS_PROF="$TMP/install_ps1_prof.ps1"
        PS_PROF_WIN="$PS_PROF"
        if command -v cygpath >/dev/null 2>&1; then
            PS_PROF_WIN=$(cygpath -w "$PS_PROF")
        fi
        "$ps_cmd" -NoProfile -ExecutionPolicy Bypass -File "$inst_ps1_win" -Yes -ProfilePath "$PS_PROF_WIN" >/dev/null 2>&1
        check_exit "ps1 install exits 0" 0 "$?"
        [ -f "$PS_PROF" ] && grep -q "GitWhisper >>>" "$PS_PROF" \
            && pass "ps1 install appends marker block" \
            || fail "ps1 install appends marker block"
        "$ps_cmd" -NoProfile -ExecutionPolicy Bypass -File "$inst_ps1_win" -Uninstall -ProfilePath "$PS_PROF_WIN" >/dev/null 2>&1
        check_exit "ps1 uninstall exits 0" 0 "$?"
        grep -q "GitWhisper >>>" "$PS_PROF" && fail "ps1 uninstall removes block" || pass "ps1 uninstall removes block"
    else
        echo "  skip ps1 installer tests (no powershell.exe/pwsh)"
    fi
}

#
# commit-dependent tests (only when GW_TEST_COMMITS=1; require working `git commit`)
#
test_commit_flow() {
    if [ "${GW_TEST_COMMITS:-0}" != "1" ]; then
        echo "  skip commit-dependent tests (set GW_TEST_COMMITS=1 to run)"
        return
    fi
    new_repo
    add_file "app.js" "console.log(1)"
    run_sh "" init >/dev/null 2>&1

    run_sh "" changelog >/dev/null 2>&1
    check_exit "changelog no commits exits 0" 0 "$RUN_EXIT"
    check_contains "changelog warns when no commits" "No commits" "$RUN_OUT"
    check_not_contains "changelog no fatal leak" "fatal:" "$RUN_OUT"

    run_ps1 "" changelog >/dev/null 2>&1
    check_exit "ps1 changelog no commits exits 0" 0 "$RUN_EXIT"
    check_contains "ps1 changelog warns when no commits" "No commits" "$RUN_OUT"
    check_not_contains "ps1 changelog no fatal leak" "fatal:" "$RUN_OUT"
}

test_commit_flow_custom_config() {
    if [ "${GW_TEST_COMMITS:-0}" != "1" ]; then
        echo "  skip commit-dependent custom-config tests (set GW_TEST_COMMITS=1 to run)"
        return
    fi
    new_repo
    add_file "app.js" "console.log(1)"
    cat > .gitwhisperconfig <<'EOF'
[types]
security = x|Security
security.order = 1
fix.order = 2
EOF
    run_sh "" init >/dev/null 2>&1
    git commit -q -m "security: harden auth endpoint" --no-verify
    add_file "README.md" "readme"
    git commit -q -m "fix: resolve crash" --no-verify

    run_sh "" changelog >/dev/null 2>&1
    check_exit "changelog with custom types exits 0" 0 "$RUN_EXIT"
    check_contains "changelog uses custom section title" "Security" "$RUN_OUT"
    check_contains "changelog keeps default title" "Bug Fixes" "$RUN_OUT"

    local sec_line fix_line
    sec_line=$(printf '%s\n' "$RUN_OUT" | grep -n "Security" | head -1 | cut -d: -f1)
    fix_line=$(printf '%s\n' "$RUN_OUT" | grep -n "Bug Fixes" | head -1 | cut -d: -f1)
    if [ -n "$sec_line" ] && [ -n "$fix_line" ] && [ "$sec_line" -lt "$fix_line" ]; then
        pass "changelog respects type.order (Security before Bug Fixes)"
    else
        fail "changelog respects type.order (Security before Bug Fixes)" "Security at line $sec_line, Bug Fixes at line $fix_line"
    fi

    if [ "$HAVE_PS1" = true ]; then
        run_ps1 "" changelog >/dev/null 2>&1
        check_exit "ps1 changelog with custom types exits 0" 0 "$RUN_EXIT"
        check_contains "ps1 changelog uses custom section title" "Security" "$RUN_OUT"
        sec_line=$(printf '%s\n' "$RUN_OUT" | grep -n "Security" | head -1 | cut -d: -f1)
        fix_line=$(printf '%s\n' "$RUN_OUT" | grep -n "Bug Fixes" | head -1 | cut -d: -f1)
        if [ -n "$sec_line" ] && [ -n "$fix_line" ] && [ "$sec_line" -lt "$fix_line" ]; then
            pass "ps1 changelog respects type.order"
        else
            fail "ps1 changelog respects type.order" "Security at line $sec_line, Bug Fixes at line $fix_line"
        fi
    fi
}

#
# main
#
echo "=== GitWhisper tests ==="
echo ""
echo "--- help / commands ---"
test_help
test_undo_empty
echo ""
echo "--- suggest / message generation ---"
test_suggest_basics
test_suggest_scopes_and_types
test_suggest_multiple_and_empty
test_suggest_branch_type
test_suggest_type_refinement
test_suggest_config
test_custom_config
echo ""
echo "--- init ---"
test_init_creates_files
test_init_force_and_backup
test_init_hook_toggles
echo ""
echo "--- hook behavior ---"
test_prepare_hook
test_commit_msg_hook
echo ""
echo "--- interactive commit flow ---"
test_interactive_commit
echo ""
echo "--- self-script noise filtering ---"
test_self_script_noise
echo ""
echo "--- installers ---"
test_installers
echo ""
echo "--- parity ps1 vs sh ---"
test_parity_cases
echo ""
echo "--- commit-dependent ---"
test_commit_flow
test_commit_flow_custom_config
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
