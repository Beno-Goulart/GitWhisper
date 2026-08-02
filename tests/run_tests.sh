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
    local win="$PS1"
    if command -v cygpath >/dev/null 2>&1; then
        win=$(cygpath -m "$PS1")
    fi
    RUN_OUT=$(printf '%s\n' "$stdin_data" | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win" "$@" 2>&1)
    RUN_EXIT=$?
}

new_repo() {
    REPO_COUNTER=$((REPO_COUNTER + 1))
    REPO="$TMP/repo$REPO_COUNTER"
    git init -q "$REPO"
    git -C "$REPO" config user.email "test@example.com"
    git -C "$REPO" config user.name "Test"
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
if command -v powershell.exe >/dev/null 2>&1 && [ -f "$PS1" ]; then
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
    check_contains "changelog warns when no commits" "No commits" "$RUN_OUT"
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
test_suggest_config
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
echo "--- parity ps1 vs sh ---"
test_parity_cases
echo ""
echo "--- commit-dependent ---"
test_commit_flow
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
