#!/bin/bash

# GitWhisper - Smart commit messages from git diff
# Usage: ./commit-msg.sh
# Note: Only analyzes staged changes (what will be committed)

# Check if git repo
if [[ ! -d ".git" ]]; then
    echo -e "\033[31mError: Not a git repository.\033[0m"
    exit 1
fi

# Always use staged changes (git commit only commits what's staged)
DIFF_INDEX=$(git diff --staged --name-status)
DIFF_STAT=$(git diff --staged --stat)
DIFF_CONTENT=$(git diff --staged)

if [[ -z "$DIFF_INDEX" ]]; then
    echo -e "\033[33mNo changes found.\033[0m"
    exit 0
fi

echo -e "\n\033[36m=== Changes detected ===\033[0m"
echo "$DIFF_STAT"
echo ""

# Parse files
ADDED=()
MODIFIED=()
DELETED=()
RENAMED=()

while IFS=$'\t' read -r status file; do
    status=$(echo "$status" | tr -d '[:space:]')
    case "$status" in
        A*)  ADDED+=("$file") ;;
        M*)  MODIFIED+=("$file") ;;
        D*)  DELETED+=("$file") ;;
        R*)  RENAMED+=("$file") ;;
    esac
done <<< "$DIFF_INDEX"

ALL_FILES=("${ADDED[@]}" "${MODIFIED[@]}")
ALL_CHANGED=("${ADDED[@]}" "${MODIFIED[@]}" "${DELETED[@]}")

# Convert to lowercase
ALL_FILES_LOWER=()
for f in "${ALL_FILES[@]}"; do
    ALL_FILES_LOWER+=("$(echo "$f" | tr '[:upper:]' '[:lower:]')")
done

ALL_CHANGED_LOWER=()
for f in "${ALL_CHANGED[@]}"; do
    ALL_CHANGED_LOWER+=("$(echo "$f" | tr '[:upper:]' '[:lower:]')")
done

# Helper: check if array contains pattern
contains_pattern() {
    local arr=("$@")
    local pattern="${arr[-1]}"
    unset 'arr[-1]'
    for item in "${arr[@]}"; do
        if [[ "$item" =~ $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Helper: count matches in array
count_matches() {
    local arr=("$@")
    local pattern="${arr[-1]}"
    unset 'arr[-1]'
    local count=0
    for item in "${arr[@]}"; do
        if [[ "$item" =~ $pattern ]]; then
            ((count++))
        fi
    done
    echo "$count"
}

# --- Scope detection ---
get_scope() {
    local files=("$@")
    [[ ${#files[@]} -eq 0 ]] && return

    declare -A dir_counts
    for f in "${files[@]}"; do
        dir=$(dirname "$f")
        if [[ "$dir" != "." ]]; then
            top_dir=$(echo "$dir" | cut -d'/' -f1)
            dir_counts[$top_dir]=$(( ${dir_counts[$top_dir]:-0} + 1 ))
        fi
    done

    local num_dirs=${#dir_counts[@]}
    if [[ $num_dirs -eq 1 ]]; then
        echo "${!dir_counts[0]}"
        return
    fi

    if [[ $num_dirs -gt 1 ]]; then
        local max_count=0
        local max_dir=""
        for dir in "${!dir_counts[@]}"; do
            if [[ ${dir_counts[$dir]} -gt $max_count ]]; then
                max_count=${dir_counts[$dir]}
                max_dir=$dir
            fi
        done
        local threshold=$((${#files[@]} * 60 / 100))
        if [[ $max_count -ge $threshold ]]; then
            echo "$max_dir"
            return
        fi
    fi

    if [[ ${#files[@]} -eq 1 ]]; then
        basename "${files[0]}" | sed 's/\.[^.]*$//'
        return
    fi
}

# --- Auto-scope from branch name ---
get_branch_scope() {
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    [[ -z "$branch" ]] && return

    local ignored=("main" "master" "develop" "dev" "staging" "production" "release")
    for i in "${ignored[@]}"; do
        [[ "$branch" == "$i" ]] && return
    done

    if [[ "$branch" =~ /(.+) ]]; then
        local scope="${BASH_REMATCH[1]}"
        local prefixes=("feature/" "bugfix/" "hotfix/" "fix/" "chore/" "docs/" "test/" "refactor/" "perf/" "release/")
        for p in "${prefixes[@]}"; do
            if [[ "$scope" =~ ^${p}(.+)$ ]]; then
                scope="${BASH_REMATCH[1]}"
                break
            fi
        done
        echo "$scope"
    fi
}

# --- File type detection ---
is_test_file() {
    [[ "$1" =~ (test|spec|\.test\.|\.spec\.) ]]
}

is_config_file() {
    [[ "$1" =~ (package\.json|package-lock\.json|yarn\.lock|pnpm-lock|tsconfig|jsconfig|webpack|vite\.config|rollup\.config|\.eslintrc|eslint\.config|\.prettierrc|prettier\.config|jest\.config|vitest\.config|babel\.config|\.babelrc|dockerfile|docker-compose|\.dockerignore|makefile|cmake|meson\.build|\.gitignore|\.editorconfig|\.env|turbo\.json|nx\.json|lerna\.json|pnpm-workspace|commitlint|husky|lint-staged|renovate|dependabot|\.github|netlify|vercel|firebase|railway|render) ]]
}

is_ci_file() {
    [[ "$1" =~ (\.github/workflows|\.gitlab-ci|\.circleci|\.travis|jenkins|azure-pipelines|bitbucket-pipelines) ]]
}

is_doc_file() {
    [[ "$1" =~ (readme|changelog|contributing|license|authors|docs/|\.md$|\.mdx$|\.rst$|\.txt$) ]]
}

is_style_file() {
    [[ "$1" =~ (\.css$|\.scss$|\.less$|\.sass$|\.stylus$|\.prettierrc|\.stylelintrc|stylelint) ]]
}

is_db_file() {
    [[ "$1" =~ (migration|migrate|schema|\.sql$|knex|prisma|sequelize|typeorm|drizzle) ]]
}

# --- Analyze diff content ---
ADDED_LINES=$(echo "$DIFF_CONTENT" | grep -E '^\+[^+]' || true)
REMOVED_LINES=$(echo "$DIFF_CONTENT" | grep -E '^-[^-]' || true)

# Count file types
TEST_COUNT=0
NON_TEST_COUNT=0
CONFIG_COUNT=0
CI_COUNT=0
DOC_COUNT=0
STYLE_COUNT=0
DB_COUNT=0

for f in "${ALL_CHANGED_LOWER[@]}"; do
    is_test_file "$f" && ((TEST_COUNT++)) || ((NON_TEST_COUNT++))
    is_config_file "$f" && ((CONFIG_COUNT++))
    is_ci_file "$f" && ((CI_COUNT++))
    is_doc_file "$f" && ((DOC_COUNT++))
    is_style_file "$f" && ((STYLE_COUNT++))
    is_db_file "$f" && ((DB_COUNT++))
done

# Detect performance keywords (skip for non-code files and script files)
HAS_PERF=false
IS_SCRIPT=false
for f in "${ALL_CHANGED_LOWER[@]}"; do
    if [[ "$f" =~ (commit-msg|\.sh$|\.ps1$|\.py$|\.rb$|\.js$|\.ts$) ]]; then
        IS_SCRIPT=true
        break
    fi
done

if [[ "$DIFF_CONTENT" =~ (perf|optim|cache|lazy|memo|defer|throttle|debounce|batch|index) ]]; then
    # Skip if only docs/config/test/style/script files
    if [[ $DOC_COUNT -eq 0 && $CONFIG_COUNT -eq 0 && $TEST_COUNT -eq 0 && $STYLE_COUNT -eq 0 && "$IS_SCRIPT" == false ]]; then
        HAS_PERF=true
    fi
fi

# --- Build specific description ---
SPECIFIC_PARTS=()

# Check for imports
if echo "$ADDED_LINES" | grep -qE '(import|require)'; then
    IMPORT_NAMES=$(echo "$ADDED_LINES" | grep -oE '(import|require)\s*\{?\s*[A-Za-z]+' | grep -oE '[A-Za-z]+$' | head -3 | tr '\n' ', ' | sed 's/,$//')
    [[ -n "$IMPORT_NAMES" ]] && SPECIFIC_PARTS+=("adds $IMPORT_NAMES import")
fi

# Check for functions
if echo "$ADDED_LINES" | grep -qE '(function|const|let|var)\s+[A-Za-z]'; then
    FUNC_NAMES=$(echo "$ADDED_LINES" | grep -oE '(function|const|let|var)\s+[A-Za-z]+' | grep -oE '[A-Za-z]+$' | grep -vE '^(module|exports|require|import)$' | head -2 | tr '\n' ', ' | sed 's/,$//')
    [[ -n "$FUNC_NAMES" ]] && SPECIFIC_PARTS+=("adds $FUNC_NAMES")
fi

# Check for classes
if echo "$ADDED_LINES" | grep -qE 'class\s+[A-Za-z]'; then
    CLASS_NAMES=$(echo "$ADDED_LINES" | grep -oE 'class\s+[A-Za-z]+' | grep -oE '[A-Za-z]+$' | head -2 | tr '\n' ', ' | sed 's/,$//')
    [[ -n "$CLASS_NAMES" ]] && SPECIFIC_PARTS+=("adds $CLASS_NAMES class")
fi

# Check for React hooks
if echo "$ADDED_LINES" | grep -qE '(useState|useEffect|useContext|useReducer|useMemo|useCallback|useRef)\s*\('; then
    HOOK_NAMES=$(echo "$ADDED_LINES" | grep -oE '[a-zA-Z]+\((' | grep -oE '^[a-zA-Z]+' | grep -E '^use' | head -3 | tr '\n' ', ' | sed 's/,$//')
    [[ -n "$HOOK_NAMES" ]] && SPECIFIC_PARTS+=("adds $HOOK_NAMES")
fi

# Fallback patterns
if [[ ${#SPECIFIC_PARTS[@]} -eq 0 ]]; then
    if echo "$ADDED_LINES" | grep -qE '(try|catch|throw|Error)'; then
        SPECIFIC_PARTS+=("adds error handling")
    elif echo "$ADDED_LINES" | grep -qE '(fetch|axios|http|api|endpoint)'; then
        SPECIFIC_PARTS+=("adds API call")
    elif echo "$ADDED_LINES" | grep -qE '(className|class=|style=)'; then
        SPECIFIC_PARTS+=("updates styles")
    elif echo "$ADDED_LINES" | grep -qE '(margin|padding|border|color|font|display|flex|grid)'; then
        SPECIFIC_PARTS+=("adjusts CSS properties")
    elif echo "$ADDED_LINES" | grep -qE '(onClick|onChange|onSubmit)'; then
        SPECIFIC_PARTS+=("adds event handlers")
    elif echo "$ADDED_LINES" | grep -qE '(\/\/|#|\/\*)'; then
        SPECIFIC_PARTS+=("adds comments")
    fi
fi

SPECIFIC_DESC=""
if [[ ${#SPECIFIC_PARTS[@]} -gt 0 ]]; then
    SPECIFIC_DESC=$(printf ' and %s' "${SPECIFIC_PARTS[@]}")
    SPECIFIC_DESC="${SPECIFIC_DESC:4}"
fi

# --- Determine commit type ---
COMMIT_TYPE=""
COMMIT_DESC=""

# Deleted only
if [[ ${#DELETED[@]} -gt 0 && ${#ADDED[@]} -eq 0 && ${#MODIFIED[@]} -eq 0 ]]; then
    COMMIT_TYPE="refactor"
    if [[ ${#DELETED[@]} -eq 1 ]]; then
        NAME=$(basename "${DELETED[0]}")
        if [[ -n "$SPECIFIC_DESC" ]]; then
            COMMIT_DESC="$SPECIFIC_DESC from $NAME"
        else
            COMMIT_DESC="removes $NAME"
        fi
    else
        COMMIT_DESC="removes ${#DELETED[@]} files"
    fi
# Config/build only
elif [[ $CONFIG_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 && $DOC_COUNT -eq 0 && $CI_COUNT -eq 0 ]]; then
    COMMIT_TYPE="build"
    COMMIT_DESC="updates configuration"
# CI only
elif [[ $CI_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 ]]; then
    COMMIT_TYPE="ci"
    COMMIT_DESC="updates CI pipeline"
# Documentation only
elif [[ $DOC_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 && $CONFIG_COUNT -eq 0 ]]; then
    COMMIT_TYPE="docs"
    if [[ -n "$SPECIFIC_DESC" ]]; then
        COMMIT_DESC="$SPECIFIC_DESC"
    else
        COMMIT_DESC="updates documentation"
    fi
# Test only
elif [[ $TEST_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 ]]; then
    COMMIT_TYPE="test"
    if [[ -n "$SPECIFIC_DESC" ]]; then
        COMMIT_DESC="$SPECIFIC_DESC"
    else
        COMMIT_DESC="updates tests"
    fi
# Style only
elif [[ $STYLE_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 ]]; then
    COMMIT_TYPE="style"
    if [[ -n "$SPECIFIC_DESC" ]]; then
        COMMIT_DESC="$SPECIFIC_DESC"
    else
        COMMIT_DESC="fixes formatting"
    fi
# DB/migrations
elif [[ $DB_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 ]]; then
    COMMIT_TYPE="db"
    COMMIT_DESC="updates database schema"
# Performance
elif [[ "$HAS_PERF" == true ]]; then
    COMMIT_TYPE="perf"
    COMMIT_DESC="improves performance"
# New files added
elif [[ ${#ADDED[@]} -gt 0 && ${#MODIFIED[@]} -eq 0 && ${#DELETED[@]} -eq 0 ]]; then
    COMMIT_TYPE="feat"
    if [[ ${#ADDED[@]} -eq 1 ]]; then
        NAME=$(basename "${ADDED[0]}")
        EXT="${NAME##*.}"
        case "$EXT" in
            css|scss|less|sass)
                COMMIT_TYPE="style"
                COMMIT_DESC="adds styles for $(basename "$NAME" | sed "s/\.[^.]*$//")"
                ;;
            md|mdx|rst|txt)
                COMMIT_TYPE="docs"
                COMMIT_DESC="adds $NAME"
                ;;
            *)
                if [[ -n "$SPECIFIC_DESC" ]]; then
                    COMMIT_DESC="$SPECIFIC_DESC in $(basename "$NAME" | sed "s/\.[^.]*$//")"
                else
                    COMMIT_DESC="adds $NAME"
                fi
                ;;
        esac
    else
        COMMIT_DESC="adds ${#ADDED[@]} files"
    fi
# Only modifications
elif [[ ${#ADDED[@]} -eq 0 && ${#MODIFIED[@]} -gt 0 && ${#DELETED[@]} -eq 0 ]]; then
    if [[ ${#MODIFIED[@]} -eq 1 ]]; then
        NAME=$(basename "${MODIFIED[0]}")
        EXT="${NAME##*.}"
        case "$EXT" in
            md|mdx|rst|txt)
                COMMIT_TYPE="docs"
                COMMIT_DESC="updates $NAME"
                ;;
            css|scss|less|sass)
                COMMIT_TYPE="style"
                COMMIT_DESC="fixes styles in $(basename "$NAME" | sed "s/\.[^.]*$//")"
                ;;
            *)
                COMMIT_TYPE="fix"
                if [[ -n "$SPECIFIC_DESC" ]]; then
                    COMMIT_DESC="$SPECIFIC_DESC in $(basename "$NAME" | sed "s/\.[^.]*$//")"
                else
                    COMMIT_DESC="fixes $NAME"
                fi
                ;;
        esac
    else
        COMMIT_TYPE="refactor"
        COMMIT_DESC="updates ${#MODIFIED[@]} files"
    fi
# Mixed changes
else
    COMMIT_TYPE="refactor"
    if [[ -n "$SPECIFIC_DESC" ]]; then
        COMMIT_DESC="$SPECIFIC_DESC"
    else
        PARTS=()
        [[ ${#ADDED[@]} -gt 0 ]] && PARTS+=("${#ADDED[@]} added")
        [[ ${#MODIFIED[@]} -gt 0 ]] && PARTS+=("${#MODIFIED[@]} modified")
        [[ ${#DELETED[@]} -gt 0 ]] && PARTS+=("${#DELETED[@]} removed")
        COMMIT_DESC=$(IFS=', '; echo "${PARTS[*]}")
    fi
fi

# --- Get scope ---
SCOPE=$(get_scope "${ALL_FILES[@]}")
if [[ -z "$SCOPE" ]]; then
    SCOPE=$(get_branch_scope)
fi

# --- Gitmoji mapping ---
declare -A GITMOJI
GITMOJI[feat]="✨"
GITMOJI[fix]="🐛"
GITMOJI[docs]="📝"
GITMOJI[style]="💄"
GITMOJI[refactor]="♻️"
GITMOJI[perf]="⚡"
GITMOJI[test]="✅"
GITMOJI[build]="🔧"
GITMOJI[ci]="👷"
GITMOJI[chore]="🔨"
GITMOJI[db]="🗃️"
GITMOJI[revert]="⏪"

EMOJI="${GITMOJI[$COMMIT_TYPE]:-🔨}"

# --- Build messages ---
if [[ -n "$SCOPE" ]]; then
    SIMPLE_WITH_EMOJI="$EMOJI ${COMMIT_TYPE}(${SCOPE}): $COMMIT_DESC"
    SIMPLE_WITHOUT="${COMMIT_TYPE}(${SCOPE}): $COMMIT_DESC"
    DETAIL_WITH_EMOJI="$EMOJI ${COMMIT_TYPE}(${SCOPE}): $SPECIFIC_DESC"
    DETAIL_WITHOUT="${COMMIT_TYPE}(${SCOPE}): $SPECIFIC_DESC"
else
    SIMPLE_WITH_EMOJI="$EMOJI ${COMMIT_TYPE}: $COMMIT_DESC"
    SIMPLE_WITHOUT="${COMMIT_TYPE}: $COMMIT_DESC"
    DETAIL_WITH_EMOJI="$EMOJI ${COMMIT_TYPE}: $SPECIFIC_DESC"
    DETAIL_WITHOUT="${COMMIT_TYPE}: $SPECIFIC_DESC"
fi

# Use simple if no specific desc
if [[ -z "$SPECIFIC_DESC" ]]; then
    DETAIL_WITH_EMOJI="$SIMPLE_WITH_EMOJI"
    DETAIL_WITHOUT="$SIMPLE_WITHOUT"
fi

# --- Output ---
echo ""
echo -e "\033[32m=== Choose your commit message ===\033[0m"
echo ""
echo "  [1] $SIMPLE_WITH_EMOJI"
echo "  [2] $SIMPLE_WITHOUT"
echo "  [3] $DETAIL_WITH_EMOJI"
echo "  [4] $DETAIL_WITHOUT"
echo -e "  [0] \033[90mCancel\033[0m"
echo ""

read -p "  Select (0-4): " CHOICE

case "$CHOICE" in
    1) SELECTED_MSG="$SIMPLE_WITH_EMOJI" ;;
    2) SELECTED_MSG="$SIMPLE_WITHOUT" ;;
    3) SELECTED_MSG="$DETAIL_WITH_EMOJI" ;;
    4) SELECTED_MSG="$DETAIL_WITHOUT" ;;
    *)
        echo ""
        echo -e "  \033[33mCancelled.\033[0m"
        exit 0
        ;;
esac

echo ""
echo -e "  \033[36mCommitting: $SELECTED_MSG\033[0m"
git commit -m "$SELECTED_MSG"

if [[ $? -eq 0 ]]; then
    echo ""
    read -p "  Push to remote? (y/n): " PUSH
    if [[ "$PUSH" == "y" || "$PUSH" == "Y" ]]; then
        echo ""
        echo -e "  \033[36mPushing...\033[0m"
        git push
        if [[ $? -eq 0 ]]; then
            echo -e "  \033[32mPushed successfully!\033[0m"
        else
            echo -e "  \033[31mPush failed.\033[0m"
        fi
    fi
else
    echo ""
    echo -e "  \033[31mCommit failed.\033[0m"
fi
