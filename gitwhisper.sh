#!/usr/bin/env bash

set -e

show_help() {
    echo ""
    echo "=== GitWhisper ==="
    echo ""
    echo "  Usage:"
    echo "    gitwhisper               - generate commit message"
    echo "    gitwhisper commit        - generate commit message"
    echo "    gitwhisper undo          - undo last commit"
    echo "    gitwhisper amend         - amend last commit"
    echo "    gitwhisper changelog     - generate changelog"
    echo "    gitwhisper release       - create release (changelog + tag)"
    echo "    gitwhisper release --push   - push commit and tag after release"
    echo "    gitwhisper release --github - also publish a GitHub Release (gh CLI)"
    echo "    gitwhisper release --minor  - force minor bump (major/minor/patch)"
    echo "    gitwhisper release --version 1.2.3 - use explicit version"
    echo "    gitwhisper help          - show this help"
    echo "    gitwhisper pr            - generate PR description"
    echo "    gitwhisper pr --base main   - specify base branch"
    echo "    gitwhisper --dry-run     - show message without committing"
    echo "    gitwhisper init           - create config + install smart git hooks"
    echo "    gitwhisper init --force   - recreate config + overwrite hooks"
    echo "    gitwhisper suggest        - print suggested message (used by hooks)"
    echo ""
    exit 0
}

DRY_RUN=false
CMD="${1:-}"

if [ "$CMD" = "help" ] || [ "$CMD" = "--help" ] || [ "$CMD" = "-h" ]; then
    show_help
fi

if [ "$CMD" = "--dry-run" ] || [ "$CMD" = "-n" ]; then
    DRY_RUN=true
    CMD=""
fi

if [[ ! -d ".git" ]]; then
    echo -e "\033[31mError: Not a git repository.\033[0m"
    exit 1
fi

invoke_undo() {
    LAST_MSG=$(git log -1 --format="%s" 2>/dev/null || true)
    if [[ -z "$LAST_MSG" ]]; then
        echo -e "\033[33mNothing to undo.\033[0m"
        exit 0
    fi

    echo ""
    echo -e "\033[36m=== Undo last commit ===\033[0m"
    echo ""
    echo "  Last commit: $LAST_MSG"
    echo ""
    echo "  [1] Soft reset  — keeps changes staged"
    echo "  [2] Mixed reset — unstages changes (keeps files)"
    echo -e "  [0] \033[90mCancel\033[0m"
    echo ""

    read -p "  Select (0-2): " RESET_CHOICE

    case "$RESET_CHOICE" in
        1)
            git reset --soft HEAD~1
            if [[ $? -eq 0 ]]; then
                echo ""
                echo -e "  \033[32mUndone (soft). Changes are still staged.\033[0m"
            else
                echo ""
                echo -e "  \033[31mUndo failed.\033[0m"
            fi
            ;;
        2)
            git reset HEAD~1
            if [[ $? -eq 0 ]]; then
                echo ""
                echo -e "  \033[32mUndone (mixed). Changes are unstaged.\033[0m"
            else
                echo ""
                echo -e "  \033[31mUndo failed.\033[0m"
            fi
            ;;
        *)
            echo ""
            echo -e "  \033[33mCancelled.\033[0m"
            ;;
    esac
    exit 0
}

invoke_amend() {
    LAST_MSG=$(git log -1 --format="%s" 2>/dev/null || true)
    LAST_BODY=$(git log -1 --format="%b" 2>/dev/null || true)
    if [[ -z "$LAST_MSG" ]]; then
        echo -e "\033[33mNo commits to amend.\033[0m"
        exit 0
    fi

    echo ""
    echo -e "\033[36m=== Amend last commit ===\033[0m"
    echo ""
    echo -e "  Last message: \033[37m$LAST_MSG\033[0m"
    if [[ -n "$LAST_BODY" ]]; then
        echo -e "  \033[90mBody:\033[0m"
        while IFS= read -r line; do
            echo -e "  \033[90m  $line\033[0m"
        done <<< "$LAST_BODY"
    fi
    echo ""

    TEMP_FILE=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/gitwhisper-msg.txt")
    if [[ -n "$LAST_BODY" ]]; then
        printf '%s\n\n%s\n' "$LAST_MSG" "$LAST_BODY" > "$TEMP_FILE"
    else
        printf '%s\n' "$LAST_MSG" > "$TEMP_FILE"
    fi

    echo -e "  \033[33mOpening editor to edit message...\033[0m"
    git commit --amend -F "$TEMP_FILE"
    rm -f "$TEMP_FILE"

    if [[ $? -eq 0 ]]; then
        echo ""
        echo -e "  \033[32mCommit amended!\033[0m"
        read -p "  Force push? (y/n): " PUSH_AMEND
        if [[ "$PUSH_AMEND" == "y" || "$PUSH_AMEND" == "Y" ]]; then
            echo ""
            echo -e "  \033[36mForce pushing...\033[0m"
            git push --force-with-lease
            if [[ $? -eq 0 ]]; then
                echo -e "  \033[32mPushed successfully!\033[0m"
            else
                echo -e "  \033[31mPush failed.\033[0m"
            fi
        fi
    else
        echo ""
        echo -e "  \033[31mAmend failed.\033[0m"
    fi
}

edit_message_body() {
    local -a body=("$@")
    local -a edited_body=()
    local i edit_line new_line
    for ((i=0; i<${#body[@]}; i++)); do
        echo ""
        echo -e "  \033[90m[$((i+1))]\033[0m ${body[$i]}"
        read -p "  Edit (Enter=keep, '.=delete, '+=add after): " edit_line
        if [[ "$edit_line" == "." ]]; then
            continue
        elif [[ "$edit_line" == "+" ]]; then
            edited_body+=("${body[$i]}")
            read -p "  New line: " new_line
            [[ -n "$new_line" ]] && edited_body+=("$new_line")
        elif [[ -z "$edit_line" ]]; then
            edited_body+=("${body[$i]}")
        else
            edited_body+=("$edit_line")
        fi
    done
    printf '%s\n' "${edited_body[@]}"
}

remove_literal_strings() {
    perl -pe $'s/"(?:\\\\.|[^"\\\\])*"/""/g; s/\x27(?:\\\\.|[^\x27\\\\])*\x27/\x27\x27/g' <<< "$1"
}

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

count_matches() {
    local arr=("$@")
    local pattern="${arr[-1]}"
    unset 'arr[-1]'
    local count=0
    for item in "${arr[@]}"; do
        if [[ "$item" =~ $pattern ]]; then
            ((count+=1))
        fi
    done
    echo "$count"
}

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
        echo "${!dir_counts[@]}"
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

get_branch_type() {
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
    [[ -z "$branch" ]] && return
    case "${branch%%/*}" in
        feat|feature)            echo "feat" ;;
        fix|bugfix|bug|hotfix)   echo "fix" ;;
        docs|doc)                echo "docs" ;;
        test|tests)              echo "test" ;;
        chore)                   echo "chore" ;;
        refactor|refactoring)    echo "refactor" ;;
        perf)                    echo "perf" ;;
        style)                   echo "style" ;;
        ci)                      echo "ci" ;;
        build)                   echo "build" ;;
    esac
}

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

# Builds the message from globals ADDED, MODIFIED, DELETED and DIFF_CONTENT.
# Sets globals: SELF_SCRIPT, SPECIFIC_DESC, COMMIT_TYPE, COMMIT_DESC, SCOPE,
# SIMPLE_WITH_EMOJI, SIMPLE_WITHOUT, DETAIL_WITH_EMOJI, DETAIL_WITHOUT, BODY_PARTS.
prepare_message() {
    ALL_FILES=("${ADDED[@]}" "${MODIFIED[@]}")
    ALL_CHANGED=("${ADDED[@]}" "${MODIFIED[@]}" "${DELETED[@]}")

    ALL_FILES_LOWER=()
    for f in "${ALL_FILES[@]}"; do
        ALL_FILES_LOWER+=("$(echo "$f" | tr '[:upper:]' '[:lower:]')")
    done

    ALL_CHANGED_LOWER=()
    for f in "${ALL_CHANGED[@]}"; do
        ALL_CHANGED_LOWER+=("$(echo "$f" | tr '[:upper:]' '[:lower:]')")
    done

    SELF_SCRIPT=false
    for f in "${ALL_CHANGED_LOWER[@]}"; do
        if [[ "$f" =~ gitwhisper|^install\.(ps1|sh)$ ]]; then
            SELF_SCRIPT=true
            break
        fi
    done

    if [[ "$SELF_SCRIPT" == true ]]; then
        DIFF_CONTENT=$(remove_literal_strings "$DIFF_CONTENT")
    fi

    ADDED_LINES=$(echo "$DIFF_CONTENT" | grep -E '^\+[^+]' || true)
    REMOVED_LINES=$(echo "$DIFF_CONTENT" | grep -E '^-[^-]' || true)

    TEST_COUNT=0
    NON_TEST_COUNT=0
    CONFIG_COUNT=0
    CI_COUNT=0
    DOC_COUNT=0
    STYLE_COUNT=0
    DB_COUNT=0
    OTHER_COUNT=0

    for f in "${ALL_CHANGED_LOWER[@]}"; do
        is_test_file "$f" && ((TEST_COUNT+=1)) || ((NON_TEST_COUNT+=1))
        is_config_file "$f" && ((CONFIG_COUNT+=1))
        is_ci_file "$f" && ((CI_COUNT+=1))
        is_doc_file "$f" && ((DOC_COUNT+=1))
        is_style_file "$f" && ((STYLE_COUNT+=1))
        is_db_file "$f" && ((DB_COUNT+=1))
        if ! is_test_file "$f" && ! is_config_file "$f" && ! is_ci_file "$f" && ! is_doc_file "$f" && ! is_style_file "$f" && ! is_db_file "$f"; then
            ((OTHER_COUNT+=1))
        fi
    done

    HAS_PERF=false
    IS_SCRIPT=false
    for f in "${ALL_CHANGED_LOWER[@]}"; do
        if [[ "$f" =~ (gitwhisper|\.sh$|\.ps1$|\.py$|\.rb$|\.js$|\.ts$) ]]; then
            IS_SCRIPT=true
            break
        fi
    done

    PERF_CONTENT=$(echo "$DIFF_CONTENT" | grep -E '^[+-][^+-]' || true)
    if [[ "$PERF_CONTENT" =~ (perf|optim|cache|lazy|memo|defer|throttle|debounce|batch|index) ]]; then
        if [[ $DOC_COUNT -eq 0 && $CONFIG_COUNT -eq 0 && $TEST_COUNT -eq 0 && $STYLE_COUNT -eq 0 && "$IS_SCRIPT" == false ]]; then
            HAS_PERF=true
        fi
    fi

    SPECIFIC_PARTS=()

    NEW_BASH_FLAGS=$(echo "$ADDED_LINES" | grep -oE '"--?[a-z]+"' | grep -oE '[a-z]+' | grep -vE '^(y|n|yes|no)$' | head -3 | tr '\n' ', ' | sed 's/,$//')
    [[ -n "$NEW_BASH_FLAGS" ]] && SPECIFIC_PARTS+=("adds --$NEW_BASH_FLAGS option")

    BASH_FUNCS=$(echo "$ADDED_LINES" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{' | grep -oE '^[a-zA-Z_]+' | grep -vE '^(contains_pattern|count_matches)$' | head -3 | tr '\n' ', ' | sed 's/,$//')
    [[ -n "$BASH_FUNCS" ]] && SPECIFIC_PARTS+=("adds $BASH_FUNCS function")

    HAS_HIGH_PRIORITY=false
    [[ ${#SPECIFIC_PARTS[@]} -ge 2 ]] && HAS_HIGH_PRIORITY=true

    if [[ "$HAS_HIGH_PRIORITY" == false ]]; then
        GIT_OPS=$(echo "$ADDED_LINES" | grep -oE 'git\s+(reset|commit|push|pull|merge|rebase|stash|tag|branch|checkout|diff|log|status|add|rm|mv)' | grep -oE '(reset|commit|push|pull|merge|rebase|stash|tag|branch|checkout|diff|log|status|add|rm|mv)' | head -3 | tr '\n' ', ' | sed 's/,$//')
        [[ -n "$GIT_OPS" ]] && SPECIFIC_PARTS+=("adds git $GIT_OPS")
    fi

    if [[ "$HAS_HIGH_PRIORITY" == false ]]; then
        ECHO_MSGS=$(echo "$ADDED_LINES" | grep -oE 'echo -e?\s+"[^"]{5,50}"' | grep -oE '"[^"]*"' | tr -d '"' | sed 's/  */ /g' | grep -vE '^(Error|Warning|Pushing|Committing|Select|Cancel|Changes|===)' | head -2 | tr '\n' ', ' | sed 's/,$//')
        [[ -n "$ECHO_MSGS" ]] && SPECIFIC_PARTS+=("adds $ECHO_MSGS messages")
    fi

    if echo "$ADDED_LINES" | grep -qE '(import|require)\s*\{?\s*[A-Za-z]'; then
        IMPORT_NAMES=$(echo "$ADDED_LINES" | grep -oE '(import|require)\s*\{?\s*[A-Za-z]+' | grep -oE '[A-Za-z]+$' | head -3 | tr '\n' ', ' | sed 's/,$//')
        [[ -n "$IMPORT_NAMES" ]] && SPECIFIC_PARTS+=("adds $IMPORT_NAMES import")
    fi

    if echo "$ADDED_LINES" | grep -qE 'class\s+[A-Za-z]'; then
        CLASS_NAMES=$(echo "$ADDED_LINES" | grep -oE 'class\s+[A-Za-z]+' | grep -oE '[A-Za-z]+$' | head -2 | tr '\n' ', ' | sed 's/,$//')
        [[ -n "$CLASS_NAMES" ]] && SPECIFIC_PARTS+=("adds $CLASS_NAMES class")
    fi

    if echo "$ADDED_LINES" | grep -qE '(useState|useEffect|useContext|useReducer|useMemo|useCallback|useRef)\s*\('; then
        HOOK_NAMES=$(echo "$ADDED_LINES" | grep -oE '[a-zA-Z]+\((' | grep -oE '^[a-zA-Z]+' | grep -E '^use' | head -3 | tr '\n' ', ' | sed 's/,$//')
        [[ -n "$HOOK_NAMES" ]] && SPECIFIC_PARTS+=("adds $HOOK_NAMES")
    fi

    if [[ ${#SPECIFIC_PARTS[@]} -eq 0 ]]; then
        SCRIPT_FILES=()
        DOC_FILES=()
        OTHER_FILES=()

        for f in "${ADDED[@]}" "${MODIFIED[@]}"; do
            [[ -z "$f" ]] && continue
            BASENAME=$(basename "$f" | sed 's/\.[^.]*$//')
            LOWER=$(echo "$f" | tr '[:upper:]' '[:lower:]')
            if [[ "$LOWER" =~ \.(sh|ps1|py|rb|js|ts)$ || "$LOWER" =~ gitwhisper|changelog ]]; then
                SCRIPT_FILES+=("$BASENAME")
            elif [[ "$LOWER" =~ \.(md|mdx|rst|txt)$ || "$LOWER" =~ readme|changelog|contributing|license ]]; then
                DOC_FILES+=("$BASENAME")
            else
                OTHER_FILES+=("$BASENAME")
            fi
        done

        MIX_PARTS=()
        [[ ${#SCRIPT_FILES[@]} -gt 0 ]] && MIX_PARTS+=("scripts ($(IFS=', '; echo "${SCRIPT_FILES[*]:0:3}"))")
        [[ ${#DOC_FILES[@]} -gt 0 ]] && MIX_PARTS+=("docs ($(IFS=', '; echo "${DOC_FILES[*]:0:3}"))")
        [[ ${#OTHER_FILES[@]} -gt 0 ]] && MIX_PARTS+=("$(IFS=', '; echo "${OTHER_FILES[*]:0:3}")")

        if [[ ${#MIX_PARTS[@]} -gt 0 ]]; then
            SPECIFIC_PARTS+=("updates $(IFS=' and '; echo "${MIX_PARTS[*]}")")
        elif [[ ${#DELETED[@]} -gt 0 ]]; then
            DEL_NAMES=""
            for f in "${DELETED[@]:0:2}"; do
                [[ -n "$DEL_NAMES" ]] && DEL_NAMES+=", "
                DEL_NAMES+="$(basename "$f")"
            done
            SPECIFIC_PARTS+=("removes $DEL_NAMES")
        fi
    fi

    SPECIFIC_DESC=""
    if [[ ${#SPECIFIC_PARTS[@]} -gt 0 ]]; then
        SPECIFIC_DESC=$(printf ' and %s' "${SPECIFIC_PARTS[@]}" | sed 's/  */ /g')
        SPECIFIC_DESC="${SPECIFIC_DESC:5}"
    fi

    COMMIT_TYPE=""
    COMMIT_DESC=""
    COMMIT_STRONG=true

    if [[ ${#DELETED[@]} -gt 0 && ${#ADDED[@]} -eq 0 && ${#MODIFIED[@]} -eq 0 ]]; then
        DEL_DOCS=1
        for F in "${DELETED[@]}"; do
            if ! echo "$F" | grep -qE '\.(md|mdx|rst|txt)$|readme|changelog|docs/'; then
                DEL_DOCS=0
                break
            fi
        done
        if [[ "$DEL_DOCS" == 1 ]]; then
            COMMIT_TYPE="docs"
            if [[ ${#DELETED[@]} -eq 1 ]]; then
                COMMIT_DESC="removes $(basename "${DELETED[0]}")"
            else
                COMMIT_DESC="removes ${#DELETED[@]} documentation files"
            fi
        else
            COMMIT_STRONG=false
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
        fi
    elif [[ $CONFIG_COUNT -gt 0 && $OTHER_COUNT -eq 0 && $DOC_COUNT -eq 0 && $CI_COUNT -eq 0 ]]; then
        COMMIT_TYPE="build"
        COMMIT_DESC="updates configuration"
    elif [[ $CI_COUNT -gt 0 && $OTHER_COUNT -eq 0 ]]; then
        COMMIT_TYPE="ci"
        COMMIT_DESC="updates CI pipeline"
    elif [[ $DOC_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 && $CONFIG_COUNT -eq 0 ]]; then
        COMMIT_TYPE="docs"
        if [[ -n "$SPECIFIC_DESC" ]]; then
            COMMIT_DESC="$SPECIFIC_DESC"
        else
            COMMIT_DESC="updates documentation"
        fi
    elif [[ $TEST_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 ]]; then
        COMMIT_TYPE="test"
        if [[ -n "$SPECIFIC_DESC" ]]; then
            COMMIT_DESC="$SPECIFIC_DESC"
        else
            COMMIT_DESC="updates tests"
        fi
    elif [[ $STYLE_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 ]]; then
        COMMIT_TYPE="style"
        if [[ -n "$SPECIFIC_DESC" ]]; then
            COMMIT_DESC="$SPECIFIC_DESC"
        else
            COMMIT_DESC="fixes formatting"
        fi
    elif [[ $DB_COUNT -gt 0 && $OTHER_COUNT -eq 0 ]]; then
        if [[ ${#ADDED[@]} -gt 0 && ${#MODIFIED[@]} -eq 0 ]]; then
            COMMIT_TYPE="feat"
            TABLES=$(echo "$DIFF_CONTENT" | grep -oE '(CREATE TABLE|ALTER TABLE|INSERT INTO)[[:space:]]+[A-Za-z0-9_]+' | sed -E 's/^(CREATE TABLE|ALTER TABLE|INSERT INTO)[[:space:]]+//' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
            if [[ -n "$TABLES" ]]; then
                COMMIT_DESC="adds migration for $TABLES"
            else
                COMMIT_DESC="adds database migration"
            fi
        else
            COMMIT_TYPE="fix"
            COMMIT_DESC="fixes database schema"
        fi
    elif [[ "$HAS_PERF" == true ]]; then
        COMMIT_TYPE="perf"
        COMMIT_DESC="improves performance"
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
                    COMMIT_STRONG=false
                    if [[ -n "$SPECIFIC_DESC" ]]; then
                        COMMIT_DESC="$SPECIFIC_DESC in $(basename "$NAME" | sed "s/\.[^.]*$//")"
                    else
                        COMMIT_DESC="adds $NAME"
                    fi
                    ;;
            esac
        else
            COMMIT_STRONG=false
            COMMIT_DESC="adds ${#ADDED[@]} files"
        fi
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
                    COMMIT_STRONG=false
                    COMMIT_TYPE="fix"
                    if [[ -n "$SPECIFIC_DESC" ]]; then
                        COMMIT_DESC="$SPECIFIC_DESC in $(basename "$NAME" | sed "s/\.[^.]*$//")"
                    else
                        COMMIT_DESC="fixes $NAME"
                    fi
                    ;;
            esac
        else
            COMMIT_STRONG=false
            if [[ -n "$SPECIFIC_DESC" && "$SPECIFIC_DESC" == *"adds "* ]]; then
                COMMIT_TYPE="feat"
                COMMIT_DESC="$SPECIFIC_DESC"
            elif [[ -n "$SPECIFIC_DESC" && "$SPECIFIC_DESC" == *"removes "* ]]; then
                COMMIT_TYPE="refactor"
                COMMIT_DESC="$SPECIFIC_DESC"
            elif [[ -n "$SPECIFIC_DESC" ]]; then
                COMMIT_TYPE="fix"
                COMMIT_DESC="$SPECIFIC_DESC"
            else
                COMMIT_TYPE="fix"
                COMMIT_DESC="updates ${#MODIFIED[@]} files"
            fi
        fi
    else
        COMMIT_STRONG=false
        if [[ -n "$SPECIFIC_DESC" && "$SPECIFIC_DESC" == *"adds "* ]]; then
            COMMIT_TYPE="feat"
            COMMIT_DESC="$SPECIFIC_DESC"
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
    fi

    BRANCH_TYPE=$(get_branch_type)
    if [[ -n "$BRANCH_TYPE" && "$COMMIT_STRONG" == "false" ]]; then
        COMMIT_TYPE="$BRANCH_TYPE"
    fi

    SCOPE=$(get_scope "${ALL_FILES[@]}")
    if [[ -z "$SCOPE" ]]; then
        SCOPE=$(get_branch_scope)
    fi

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

    if [[ -z "$SPECIFIC_DESC" ]]; then
        DETAIL_WITH_EMOJI="$SIMPLE_WITH_EMOJI"
        DETAIL_WITHOUT="$SIMPLE_WITHOUT"
    fi

    BODY_PARTS=()
    if [[ ${#ADDED[@]} -gt 0 ]]; then
        BODY_PARTS+=("Added:")
        for f in "${ADDED[@]}"; do
            BODY_PARTS+=("  - $f")
        done
    fi
    if [[ ${#MODIFIED[@]} -gt 0 ]]; then
        BODY_PARTS+=("Modified:")
        for f in "${MODIFIED[@]}"; do
            BODY_PARTS+=("  - $f")
        done
    fi
    if [[ ${#DELETED[@]} -gt 0 ]]; then
        BODY_PARTS+=("Removed:")
        for f in "${DELETED[@]}"; do
            BODY_PARTS+=("  - $f")
        done
    fi
    BODY_PARTS+=("")
    BODY_PARTS+=("Change summary: $COMMIT_DESC")
    if [[ -n "$SPECIFIC_DESC" && "$SPECIFIC_DESC" != "$COMMIT_DESC" ]]; then
        BODY_PARTS+=("Details: $SPECIFIC_DESC")
    fi
}

load_gw_config() {
    GW_CONFIG=()
    if [[ ! -f ".gitwhisperconfig" ]]; then
        return 0
    fi
    local section="" raw key val
    while IFS= read -r raw; do
        raw=$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$raw" ]] && continue
        [[ "$raw" == \#* || "$raw" == \;* ]] && continue
        if [[ "$raw" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            section=$(echo "$section" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            continue
        fi
        if [[ "$raw" =~ ^([^=]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
            val="${BASH_REMATCH[2]}"
            val=$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            GW_CONFIG["${section}.${key}"]="$val"
        fi
    done < ".gitwhisperconfig"
}

invoke_suggest() {
    if git diff --cached --quiet 2>/dev/null; then
        exit 0
    fi

    DIFF_INDEX=$(git diff --staged --name-status)
    DIFF_CONTENT=$(git diff --staged)

    ADDED=()
    MODIFIED=()
    DELETED=()
    while IFS=$'\t' read -r status file; do
        [[ -z "$status" && -z "$file" ]] && continue
        status=$(echo "$status" | tr -d '[:space:]')
        case "$status" in
            A*)  ADDED+=("$file") ;;
            M*)  MODIFIED+=("$file") ;;
            D*)  DELETED+=("$file") ;;
        esac
    done <<< "$DIFF_INDEX"

    prepare_message

    local default=1
    [[ -n "${GW_CONFIG[general.default]}" ]] && default="${GW_CONFIG[general.default]}"
    if [[ ! "$default" =~ ^[1-4]$ ]]; then default=1; fi

    local emoji_on=true
    [[ "${GW_CONFIG[general.emoji]}" == "false" ]] && emoji_on=false

    local title
    case "$default" in
        1) if [[ "$emoji_on" == true ]]; then title="$SIMPLE_WITH_EMOJI"; else title="$SIMPLE_WITHOUT"; fi ;;
        2) title="$SIMPLE_WITHOUT" ;;
        3) if [[ "$emoji_on" == true ]]; then title="$DETAIL_WITH_EMOJI"; else title="$DETAIL_WITHOUT"; fi ;;
        4) title="$DETAIL_WITHOUT" ;;
    esac

    printf '%s\n\n%s\n' "$title" "$(printf '%s\n' "${BODY_PARTS[@]}")"
    exit 0
}

new_gw_config_file() {
    cat > .gitwhisperconfig <<'EOF'
# GitWhisper configuration
# Created by `gitwhisper init`. Re-run `gitwhisper init` to update hooks after edits.

[general]
# include emoji in generated commit messages (true/false)
emoji = true

# suggestion pre-filled by the hook: 1=simple+emoji, 2=simple, 3=detailed+emoji, 4=detailed
default = 1

# maintainers excluded from the "community contributors" section of the changelog
core_maintainers =

[hooks]
# pre-fill the commit message on `git commit` (true/false)
prepare = true

# reject commits that do not follow Conventional Commits (true/false)
validate = true
EOF
    echo -e "  \033[32mCreated .gitwhisperconfig\033[0m"
}

get_gitwhisper_command() {
    if [[ "$0" == */* ]]; then
        local abs
        abs=$(cd "$(dirname "$0")" && pwd)
        echo "bash '$abs/$(basename "$0")'"
    else
        echo "gitwhisper"
    fi
}

get_prepare_hook_content() {
    local cmd="$1"
    cat <<EOF
#!/bin/sh
# Generated by GitWhisper init. Re-run \`gitwhisper init\` to update.
GW_CMD="$cmd"

MSG_FILE="\$1"
SOURCE="\$2"

# only pre-fill plain commits (skip -m, --amend, merge, template, etc.)
case "\$SOURCE" in
    message|template|merge|squash|commit) exit 0 ;;
esac

# do nothing when there are no staged changes
if ! git diff --cached --quiet 2>/dev/null; then
    SUGGEST=\$(eval "\$GW_CMD suggest < /dev/null" 2>/dev/null)
    if [ -n "\$SUGGEST" ]; then
        # only pre-fill when the message file has no real content yet
        REAL=\$(grep -v '^#' "\$MSG_FILE" | grep -v '^[[:space:]]*\$' | head -1)
        if [ -z "\$REAL" ]; then
            printf '%s\n' "\$SUGGEST" > "\$MSG_FILE"
        fi
    fi
fi

exit 0
EOF
}

get_commit_msg_hook_content() {
    cat <<'EOF'
#!/bin/sh
# Generated by GitWhisper init. Re-run `gitwhisper init` to update.
MSG_FILE="$1"

FIRST_LINE=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        \#*) continue ;;
        "") continue ;;
    esac
    FIRST_LINE="$line"
    break
done < "$MSG_FILE"

if ! echo "$FIRST_LINE" | grep -qE '^[^[:alnum:]]*(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert|db)(\([^)]*\))?(!)?: .+'; then
    echo ""
    echo "GitWhisper: commit message does not follow Conventional Commits."
    echo ""
    echo "  Expected: <type>(<scope>): <description>"
    echo "  Example:  feat(api): add login endpoint"
    echo ""
    echo "  Run 'gitwhisper' to generate a message, or edit the subject line."
    echo ""
    exit 1
fi

exit 0
EOF
}

install_hook() {
    local path="$1" content="$2" force="${3:-0}"

    if [[ -f "$path" ]]; then
        local existing
        existing=$(cat "$path" 2>/dev/null)
        if [[ -n "$existing" && "$existing" != *"GitWhisper"* ]]; then
            if [[ "$force" != "1" ]]; then
                echo ""
                read -p "  $(basename "$path") exists and is not from GitWhisper. Back up and overwrite? (y/n): " answer
                if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
                    echo -e "  \033[33mSkipping $(basename "$path").\033[0m"
                    return
                fi
            fi
            cp "$path" "$path.bak"
            echo -e "  \033[33mBacked up existing hook to $path.bak\033[0m"
        fi
    fi
    printf '%s\n' "$content" > "$path"
    echo -e "  \033[32mInstalled $(basename "$path")\033[0m"
}

invoke_init() {
    local force=false
    for a in "$@"; do
        [[ "$a" == "--force" || "$a" == "-Force" ]] && force=true
    done

    echo ""
    echo -e "\033[36m=== GitWhisper init ===\033[0m"
    echo ""

    if [[ -f ".gitwhisperconfig" ]]; then
        if [[ "$force" == true ]]; then
            echo -e "  \033[33m.gitwhisperconfig already exists. Recreating.\033[0m"
            new_gw_config_file
        else
            echo -e "  \033[32m.gitwhisperconfig already exists. Keeping it.\033[0m"
        fi
    else
        new_gw_config_file
    fi

    local hooks_dir=".git/hooks"
    if [[ ! -d "$hooks_dir" ]]; then
        echo ""
        echo -e "  \033[31mError: could not find $hooks_dir.\033[0m"
        exit 1
    fi

    local gw_cmd f=0
    gw_cmd=$(get_gitwhisper_command)
    [[ "$force" == true ]] && f=1

    if [[ "${GW_CONFIG[hooks.prepare]}" == "false" ]]; then
        rm -f "$hooks_dir/prepare-commit-msg"
        echo -e "  \033[33mprepare-commit-msg disabled in config. Removed.\033[0m"
    else
        install_hook "$hooks_dir/prepare-commit-msg" "$(get_prepare_hook_content "$gw_cmd")" "$f"
    fi

    if [[ "${GW_CONFIG[hooks.validate]}" == "false" ]]; then
        rm -f "$hooks_dir/commit-msg"
        echo -e "  \033[33mcommit-msg disabled in config. Removed.\033[0m"
    else
        install_hook "$hooks_dir/commit-msg" "$(get_commit_msg_hook_content)" "$f"
    fi

    echo ""
    echo -e "  \033[32mDone! GitWhisper hooks installed.\033[0m"
    echo -e "  Next 'git commit' will pre-fill a suggested message."
    echo -e "  Config file: .gitwhisperconfig"
    echo ""
}

invoke_commit() {
    UNSTAGED=$(git diff --name-only)
    UNTRACKED=$(git ls-files --others --exclude-standard)

    if [[ -n "$UNSTAGED" || -n "$UNTRACKED" ]]; then
        echo ""
        echo -e "  \033[33mUnstaged changes detected.\033[0m"
        read -p "  Stage all changes? (y/n): " STAGE_ALL
        if [[ "$STAGE_ALL" == "y" || "$STAGE_ALL" == "Y" ]]; then
            git add -A
            echo -e "  \033[32mAll changes staged.\033[0m"
        fi
    fi

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

    prepare_message

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


    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  \033[90m[DRY-RUN] Commit skipped.\033[0m"
        return
    fi

    FINAL_TITLE="$SELECTED_MSG"
    mapfile -t FINAL_BODY < <(printf '%s\n' "${BODY_PARTS[@]}")

    while true; do
        OPEN_EDITOR=false

        echo ""
        echo -e "\033[32m=== Commit preview ===\033[0m"
        echo ""
        echo -e "  \033[37m$FINAL_TITLE\033[0m"
        if [[ ${#FINAL_BODY[@]} -gt 0 ]]; then
            echo ""
            for bl in "${FINAL_BODY[@]}"; do
                echo "  $bl"
            done
        fi
        echo ""
        echo "  [1] Commit as-is"
        echo "  [2] Edit subject"
        echo "  [3] Edit body"
        echo "  [4] Open in editor"
        echo -e "  [0] \033[90mCancel\033[0m"
        echo ""
        read -p "  Choose (0-4): " ACT
        if [[ -z "$ACT" ]]; then
            echo ""
            echo -e "  \033[33mCancelled.\033[0m"
            exit 0
        fi
        case "$ACT" in
            1) break ;;
            2)
                echo ""
                echo -e "  \033[90mSubject: $FINAL_TITLE\033[0m"
                read -p "  New subject (Enter to keep): " NEW_TITLE
                [[ -n "$NEW_TITLE" ]] && FINAL_TITLE="$NEW_TITLE"
                ;;
            3)
                mapfile -t FINAL_BODY < <(edit_message_body "${FINAL_BODY[@]}")
                ;;
            4)
                OPEN_EDITOR=true
                break
                ;;
            *)
                echo ""
                echo -e "  \033[33mCancelled.\033[0m"
                exit 0
                ;;
        esac
    done

    BODY=$(printf '%s\n' "${FINAL_BODY[@]}")
    FULL_MSG="$FINAL_TITLE"$'\n'"$BODY"
    TEMP_FILE=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/gitwhisper-msg.txt")
    echo "$FULL_MSG" > "$TEMP_FILE"

    if [[ "$OPEN_EDITOR" == true ]]; then
        echo ""
        echo -e "  \033[33mOpening editor...\033[0m"
        git commit -e -F "$TEMP_FILE"
    else
        git commit -F "$TEMP_FILE"
    fi

    rm -f "$TEMP_FILE"

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
}

# GitHub usernames that belong to the project maintainers.
# They are excluded from the "community contributors" section.
CORE_MAINTAINERS=()

declare -A TYPE_TITLES
TYPE_TITLES[feat]="Features"
TYPE_TITLES[fix]="Bug Fixes"
TYPE_TITLES[perf]="Performance"
TYPE_TITLES[refactor]="Refactoring"
TYPE_TITLES[docs]="Documentation"
TYPE_TITLES[test]="Tests"
TYPE_TITLES[build]="Build"
TYPE_TITLES[ci]="CI/CD"
TYPE_TITLES[chore]="Chores"
TYPE_TITLES[style]="Style"
TYPE_TITLES[revert]="Reverts"

TYPE_ORDER=(feat fix perf refactor docs test build ci chore style revert)

declare -A RELEASE_AREAS=()
declare -A RELEASE_ENTRIES=()
declare -A RELEASE_AUTHORS=()
declare -A RELEASE_AUTHOR_ENTRIES=()

get_github_user() {
    local name="$1" email="$2"
    local u
    u=$(echo "$email" | grep -oE '^[^@+]+' | head -1)
    if [[ "$email" == *"@users.noreply.github.com"* && "$u" =~ ^[a-zA-Z0-9-]+$ ]]; then
        echo "$u"
        return
    fi
    if [[ "$name" =~ ^@([a-zA-Z0-9-]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    if [[ "$name" =~ ^[a-zA-Z0-9-]+$ ]]; then
        echo "$name"
        return
    fi
    echo ""
}

release_add_commit() {
    local type="$1" scope="$2" desc="$3" pr="$4" author="$5"
    local area="${scope:-General}"
    local entry="- ${desc}"
    [[ -n "$pr" ]] && entry+=" (#${pr})"
    local key="${area}|${type}"
    if [[ -z "${RELEASE_ENTRIES[$key]}" ]]; then
        RELEASE_ENTRIES[$key]="$entry"
    else
        RELEASE_ENTRIES[$key]+=$'\n'"$entry"
    fi
    RELEASE_AREAS[$area]=$(( ${RELEASE_AREAS[$area]:-0} + 1 ))
    if [[ -n "$author" ]]; then
        local subject="$type"
        [[ -n "$scope" ]] && subject+="($scope)"
        subject+=": $desc"
        [[ -n "$pr" ]] && subject+=" (#$pr)"
        if [[ -z "${RELEASE_AUTHOR_ENTRIES[$author]}" ]]; then
            RELEASE_AUTHOR_ENTRIES[$author]="$subject"
        else
            RELEASE_AUTHOR_ENTRIES[$author]="$subject"$'\n'"${RELEASE_AUTHOR_ENTRIES[$author]}"
        fi
        RELEASE_AUTHORS[$author]=$(( ${RELEASE_AUTHORS[$author]:-0} + 1 ))
    fi
}

build_release_notes() {
    local notes=""
    local area key type a b i inserted
    local -a areas=() sorted=()

    for area in "${!RELEASE_AREAS[@]}"; do
        [[ "$area" == "General" ]] && continue
        areas+=("$area")
    done

    for a in "${areas[@]}"; do
        inserted=false
        for i in "${!sorted[@]}"; do
            b="${sorted[$i]}"
            if (( ${RELEASE_AREAS[$b]} < ${RELEASE_AREAS[$a]} )); then
                sorted=("${sorted[@]:0:$i}" "$a" "${sorted[@]:$i}")
                inserted=true
                break
            fi
        done
        [[ "$inserted" == false ]] && sorted+=("$a")
    done
    [[ -n "${RELEASE_AREAS[General]}" ]] && sorted+=("General")

    for area in "${sorted[@]}"; do
        [[ -n "$notes" ]] && notes+=$'\n'
        notes+="### ${area^}"$'\n'$'\n'
        for type in "${TYPE_ORDER[@]}"; do
            key="$area|$type"
            if [[ -n "${RELEASE_ENTRIES[$key]}" ]]; then
                notes+="#### ${TYPE_TITLES[$type]}"$'\n'$'\n'
                notes+="${RELEASE_ENTRIES[$key]}"$'\n'$'\n'
            fi
        done
    done

    local u u2 i2 inserted2
    local -a community=() csorted=()
    for u in "${!RELEASE_AUTHORS[@]}"; do
        [[ " ${CORE_MAINTAINERS[*]} " == *" $u "* ]] && continue
        community+=("$u")
    done

    for u in "${community[@]}"; do
        inserted2=false
        for i2 in "${!csorted[@]}"; do
            u2="${csorted[$i2]}"
            if (( ${RELEASE_AUTHORS[$u2]} < ${RELEASE_AUTHORS[$u]} )); then
                csorted=("${csorted[@]:0:$i2}" "$u" "${csorted[@]:$i2}")
                inserted2=true
                break
            fi
        done
        [[ "$inserted2" == false ]] && csorted+=("$u")
    done

    if [[ ${#csorted[@]} -gt 0 ]]; then
        [[ -n "$notes" ]] && notes+=$'\n'
        notes+="### Contributors"$'\n'$'\n'
        local noun="contributors"
        [[ ${#csorted[@]} -eq 1 ]] && noun="contributor"
        notes+="Thank you to ${#csorted[@]} community $noun:"$'\n'$'\n'
        for u in "${csorted[@]}"; do
            notes+="@$u"$'\n'
            notes+="${RELEASE_AUTHOR_ENTRIES[$u]}"$'\n'$'\n'
        done
    fi

    if [[ ${#RELEASE_AUTHORS[@]} -gt 0 ]]; then
        local -a mentions=()
        for u in "${!RELEASE_AUTHORS[@]}"; do
            mentions+=("@$u")
        done
        notes+="**Contributors:** ${mentions[*]}"$'\n'
    fi

    printf '%s' "$notes"
}

invoke_changelog() {
    SINCE_TAG=false
    LIMIT=50

    while [[ $# -gt 0 ]]; do
        case $1 in
            --since-tag|-SinceTag) SINCE_TAG=true; shift ;;
            --limit|-Limit) LIMIT="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ "$SINCE_TAG" == true ]]; then
        LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
        if [[ -n "$LAST_TAG" ]]; then
            LOG=$(git log "$LAST_TAG..HEAD" --pretty=format:"%H|%s|%ad|%an|%ae" --date=short 2>/dev/null || true)
        else
            echo -e "\033[33mNo tags found. Showing all commits.\033[0m"
            LOG=$(git log --pretty=format:"%H|%s|%ad|%an|%ae" --date=short -n "$LIMIT" 2>/dev/null || true)
        fi
    else
        LOG=$(git log --pretty=format:"%H|%s|%ad|%an|%ae" --date=short -n "$LIMIT" 2>/dev/null || true)
    fi

    if [[ -z "$LOG" ]]; then
        echo -e "\033[33mNo commits found.\033[0m"
        exit 0
    fi

    RELEASE_AREAS=()
    RELEASE_ENTRIES=()
    RELEASE_AUTHORS=()
    RELEASE_AUTHOR_ENTRIES=()

    TOTAL=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        HASH=$(echo "$line" | cut -d'|' -f1)
        MESSAGE=$(echo "$line" | cut -d'|' -f2)
        DATE=$(echo "$line" | cut -d'|' -f3)
        AUTHOR_NAME=$(echo "$line" | cut -d'|' -f4)
        AUTHOR_EMAIL=$(echo "$line" | cut -d'|' -f5)

        SHORT_HASH="${HASH:0:7}"

        TYPE=$(echo "$MESSAGE" | grep -oE '[a-z]+\(' | head -1 | tr -d '(')
        if [[ -z "$TYPE" ]]; then
            TYPE=$(echo "$MESSAGE" | grep -oE '[a-z]+:' | head -1 | tr -d ':')
        fi
        SCOPE=$(echo "$MESSAGE" | grep -oE '\([^)]+\)' | head -1 | tr -d '()')
        DESC=$(echo "$MESSAGE" | sed 's/.*:[[:space:]]*//')

        PR=""
        if [[ "$DESC" =~ \(#([0-9]+)\)[[:space:]]*$ ]]; then
            PR="${BASH_REMATCH[1]}"
            DESC=$(echo "$DESC" | sed -E 's/[[:space:]]*\(#[0-9]+\)[[:space:]]*$//')
        fi

        AUTHOR_USER=$(get_github_user "$AUTHOR_NAME" "$AUTHOR_EMAIL")
        release_add_commit "$TYPE" "$SCOPE" "$DESC" "$PR" "$AUTHOR_USER"

        TOTAL=$((TOTAL + 1))
    done <<< "$LOG"

    if [[ $TOTAL -eq 0 ]]; then
        echo -e "\033[33mNo conventional commits found.\033[0m"
        exit 0
    fi

    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
    if [[ -n "$LAST_TAG" ]]; then
        CURRENT_VERSION="${LAST_TAG#v}"
    else
        CURRENT_VERSION="0.1.0"
    fi

    HAS_FEAT=$(echo "$LOG" | grep -cE '\|feat[(:]' || true)
    HAS_FIX=$(echo "$LOG" | grep -cE '\|fix[(:]' || true)
    HAS_BREAKING=$(echo "$LOG" | grep -c '!' || true)

    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

    if [[ $HAS_BREAKING -gt 0 ]]; then
        NEW_VERSION="$((MAJOR + 1)).0.0"
    elif [[ $HAS_FEAT -gt 0 ]]; then
        NEW_VERSION="${MAJOR}.$((MINOR + 1)).0"
    elif [[ $HAS_FIX -gt 0 ]]; then
        NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
    else
        NEW_VERSION="$CURRENT_VERSION"
    fi

    TODAY=$(date +%Y-%m-%d)

    NOTES=$(build_release_notes)

    {
    echo "# Changelog"
    echo ""
    echo "All notable changes to this project will be documented in this file."
    echo ""
    echo "Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)"
    echo ""
    echo "## [$NEW_VERSION]($TODAY)"
    echo ""
    echo "$NOTES"
    } > CHANGELOG.md

    echo -e "\033[32m=== Changelog generated ===\033[0m"
    echo ""
    echo -e "  Version: \033[36m$NEW_VERSION\033[0m"
    echo -e "  Commits: \033[36m$TOTAL\033[0m"
    echo -e "  File:    \033[36mCHANGELOG.md\033[0m"
    echo ""

    echo -e "\033[36m=== Preview ===\033[0m"
    echo ""
    head -30 CHANGELOG.md | while IFS= read -r line; do
        echo "  $line"
    done
    echo -e "  \033[90m...\033[0m"
}

invoke_pr() {
    BASE_BRANCH=""
    CREATE_PR=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --base) BASE_BRANCH="$2"; shift 2 ;;
            create) CREATE_PR=true; shift ;;
            *) shift ;;
        esac
    done

    BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
    if [[ -z "$BRANCH" ]]; then
        echo -e "\033[31mError: Not on a branch.\033[0m"
        exit 1
    fi

    if [[ -z "$BASE_BRANCH" ]]; then
        for try in main master develop; do
            if git rev-parse --verify "$try" &>/dev/null; then
                BASE_BRANCH="$try"
                break
            fi
        done
        if [[ -z "$BASE_BRANCH" ]]; then
            echo -e "\033[31mError: Could not detect base branch. Use --base.\033[0m"
            exit 1
        fi
    fi

    MERGE_BASE=$(git merge-base "$BASE_BRANCH" "$BRANCH" 2>/dev/null)
    if [[ -z "$MERGE_BASE" ]]; then
        echo -e "\033[31mError: Branches $BASE_BRANCH and $BRANCH have no common ancestor.\033[0m"
        exit 1
    fi

    LOG=$(git log "$MERGE_BASE..$BRANCH" --pretty=format:"%H|%s|%ad" --date=short --no-merges 2>/dev/null || true)
    if [[ -z "$LOG" ]]; then
        echo -e "\033[33mNo commits found between $BASE_BRANCH and $BRANCH.\033[0m"
        exit 0
    fi

    declare -a FEAT=() FIX=() PERF=() REFACTOR=() DOCS=() TEST=()
    declare -a BUILD=() CI=() CHORE=() STYLE=() REVERT=() OTHER=()
    TOTAL=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        HASH=$(echo "$line" | cut -d'|' -f1)
        MESSAGE=$(echo "$line" | cut -d'|' -f2)
        SHORT_HASH="${HASH:0:7}"

        TYPE=$(echo "$MESSAGE" | grep -oE '[a-z]+\(' | head -1 | tr -d '(')
        if [[ -z "$TYPE" ]]; then
            TYPE=$(echo "$MESSAGE" | grep -oE '[a-z]+:' | head -1 | tr -d ':')
        fi
        SCOPE=$(echo "$MESSAGE" | grep -oE '\([^)]+\)' | head -1 | tr -d '()')
        DESC=$(echo "$MESSAGE" | sed 's/.*:[[:space:]]*//')

        ENTRY="- "
        if [[ -n "$SCOPE" ]]; then
            ENTRY+="**${SCOPE}:** "
        fi
        ENTRY+="${DESC} (\`${SHORT_HASH}\`)"

        case "$TYPE" in
            feat)     FEAT+=("$ENTRY") ;;
            fix)      FIX+=("$ENTRY") ;;
            perf)     PERF+=("$ENTRY") ;;
            refactor) REFACTOR+=("$ENTRY") ;;
            docs)     DOCS+=("$ENTRY") ;;
            test)     TEST+=("$ENTRY") ;;
            build)    BUILD+=("$ENTRY") ;;
            ci)       CI+=("$ENTRY") ;;
            chore)    CHORE+=("$ENTRY") ;;
            style)    STYLE+=("$ENTRY") ;;
            revert)   REVERT+=("$ENTRY") ;;
            *)        OTHER+=("$ENTRY") ;;
        esac
        TOTAL=$((TOTAL + 1))
    done <<< "$LOG"

    if [[ $TOTAL -eq 0 ]]; then
        echo -e "\033[33mNo conventional commits found.\033[0m"
        exit 0
    fi

    SUMMARY="Updates codebase"
    if [[ ${#FEAT[@]} -gt 0 || ${#FIX[@]} -gt 0 ]]; then
        SUMMARY_PARTS=()
        [[ ${#FEAT[@]} -gt 0 ]] && SUMMARY_PARTS+=("adds new features")
        [[ ${#FIX[@]} -gt 0 ]] && SUMMARY_PARTS+=("fixes bugs")
        [[ ${#REFACTOR[@]} -gt 0 ]] && SUMMARY_PARTS+=("refactors codebase")
        SUMMARY=$(printf '%s; ' "${SUMMARY_PARTS[@]}")
        SUMMARY="${SUMMARY%; }"
        SUMMARY="$(tr '[:lower:]' '[:upper:]' <<< "${SUMMARY:0:1}")${SUMMARY:1}"
    fi

    PR_BODY="## Summary"
    PR_BODY+=$'\n'"$SUMMARY"
    PR_BODY+=$'\n'""
    PR_BODY+=$'\n'"## Changes"
    PR_BODY+=$'\n'""

    write_pr_section() {
        local emoji="$1"
        local title="$2"
        shift 2
        local arr=("$@")
        if [[ ${#arr[@]} -gt 0 ]]; then
            PR_BODY+=$'\n'"### $title"
            PR_BODY+=$'\n'""
            for entry in "${arr[@]}"; do
                PR_BODY+=$'\n'"$emoji $entry"
            done
            PR_BODY+=$'\n'""
        fi
    }

    write_pr_section "✨" "Features" "${FEAT[@]}"
    write_pr_section "🐛" "Bug Fixes" "${FIX[@]}"
    write_pr_section "⚡" "Performance" "${PERF[@]}"
    write_pr_section "♻️" "Refactoring" "${REFACTOR[@]}"
    write_pr_section "📝" "Documentation" "${DOCS[@]}"
    write_pr_section "✅" "Tests" "${TEST[@]}"
    write_pr_section "🔧" "Build" "${BUILD[@]}"
    write_pr_section "👷" "CI/CD" "${CI[@]}"
    write_pr_section "🔨" "Chores" "${CHORE[@]}"
    write_pr_section "💄" "Style" "${STYLE[@]}"
    write_pr_section "⏪" "Reverts" "${REVERT[@]}"
    write_pr_section "📦" "Other" "${OTHER[@]}"

    PR_BODY+=$'\n'"---"
    PR_BODY+=$'\n'"**Branch:** $BRANCH → $BASE_BRANCH"
    PR_BODY+=$'\n'"**Commits:** $TOTAL"

    echo ""
    echo -e "\033[32m=== PR Description ===\033[0m"
    echo ""
    while IFS= read -r line; do
        echo "  $line"
    done <<< "$PR_BODY"
    echo ""

    if [[ "$CREATE_PR" != true ]]; then
        read -p "  Copy to clipboard? (y/n): " COPY
        if [[ "$COPY" == "y" || "$COPY" == "Y" ]]; then
            if command -v clip.exe &>/dev/null; then
                echo "$PR_BODY" | clip.exe
            elif command -v xclip &>/dev/null; then
                echo "$PR_BODY" | xclip -selection clipboard
            elif command -v pbcopy &>/dev/null; then
                echo "$PR_BODY" | pbcopy
            else
                echo ""
                echo -e "  \033[33mNo clipboard tool found. Copy manually:\033[0m"
                echo "$PR_BODY"
                return
            fi
            echo ""
            echo -e "  \033[32mCopied to clipboard!\033[0m"
        fi
    fi

    echo ""
    if [[ "$CREATE_PR" == true ]]; then
        CREATE_NOW="y"
    else
        read -p "  Create PR now? (y/n): " CREATE_NOW
    fi
    if [[ "$CREATE_NOW" == "y" || "$CREATE_NOW" == "Y" ]]; then
        if command -v gh &>/dev/null; then
            TITLE="${FEAT[0]:-$BRANCH}"
            echo "$PR_BODY" | gh pr create --title "$TITLE" --body - --base "$BASE_BRANCH" --head "$BRANCH"
            if [[ $? -eq 0 ]]; then
                echo ""
                echo -e "  \033[32mPR created successfully!\033[0m"
            else
                echo ""
                echo -e "  \033[31mPR creation failed.\033[0m"
            fi
        else
            REMOTE_URL=$(git remote get-url origin 2>/dev/null)
            if [[ -n "$REMOTE_URL" ]]; then
                REPO=$(echo "$REMOTE_URL" | sed -E 's|.*[:/]([^/]+/[^/.]+)(\.git)?$|\1|')
                URL="https://github.com/$REPO/compare/$BASE_BRANCH...$BRANCH"
                echo ""
                echo -e "  \033[33mgh CLI not found. Opening browser...\033[0m"
                if command -v xdg-open &>/dev/null; then
                    xdg-open "$URL"
                elif command -v open &>/dev/null; then
                    open "$URL"
                fi
            fi
        fi
    fi
}

invoke_release() {
    local push=false
    local github_flag=false
    local force_type=""
    local version_override=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --push) push=true; shift ;;
            --github|-Github) github_flag=true; shift ;;
            --major) force_type="major"; shift ;;
            --minor) force_type="minor"; shift ;;
            --patch) force_type="patch"; shift ;;
            --dry-run|-n) DRY_RUN=true; shift ;;
            --version) version_override="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        echo ""
        echo -e "  \033[33mWorking tree has uncommitted changes.\033[0m"
        read -p "  Continue anyway? (y/n): " CONT
        if [[ "$CONT" != "y" && "$CONT" != "Y" ]]; then
            echo ""
            echo -e "  \033[33mCancelled.\033[0m"
            exit 0
        fi
    fi

    LAST_TAG=""
    if git describe --tags --abbrev=0 >/dev/null 2>&1; then
        LAST_TAG=$(git describe --tags --abbrev=0)
    fi

    if [[ -n "$LAST_TAG" ]]; then
        LOG=$(git log "$LAST_TAG..HEAD" --pretty=format:"%H|%s|%ad|%an|%ae" --date=short 2>/dev/null || true)
    else
        echo ""
        echo -e "  \033[33mNo tags found. Releasing from the beginning of history.\033[0m"
        LOG=$(git log --pretty=format:"%H|%s|%ad|%an|%ae" --date=short 2>/dev/null || true)
    fi

    if [[ -z "$LOG" ]]; then
        echo -e "\033[33mNo commits to release.\033[0m"
        exit 0
    fi

    RELEASE_AREAS=()
    RELEASE_ENTRIES=()
    RELEASE_AUTHORS=()
    RELEASE_AUTHOR_ENTRIES=()
    HAS_BREAKING=false
    TOTAL=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        HASH=$(echo "$line" | cut -d'|' -f1)
        MESSAGE=$(echo "$line" | cut -d'|' -f2)
        DATE=$(echo "$line" | cut -d'|' -f3)
        AUTHOR_NAME=$(echo "$line" | cut -d'|' -f4)
        AUTHOR_EMAIL=$(echo "$line" | cut -d'|' -f5)
        SHORT_HASH="${HASH:0:7}"

        TYPE=$(echo "$MESSAGE" | grep -oE '[a-z]+\(' | head -1 | tr -d '(')
        if [[ -z "$TYPE" ]]; then
            TYPE=$(echo "$MESSAGE" | grep -oE '[a-z]+:' | head -1 | tr -d ':')
        fi
        SCOPE=$(echo "$MESSAGE" | grep -oE '\([^)]+\)' | head -1 | tr -d '()')
        DESC=$(echo "$MESSAGE" | sed 's/.*:[[:space:]]*//')

        PR=""
        if [[ "$DESC" =~ \(#([0-9]+)\)[[:space:]]*$ ]]; then
            PR="${BASH_REMATCH[1]}"
            DESC=$(echo "$DESC" | sed -E 's/[[:space:]]*\(#[0-9]+\)[[:space:]]*$//')
        fi

        if [[ "$MESSAGE" == *"!"* || "$MESSAGE" == *"BREAKING CHANGE"* ]]; then
            HAS_BREAKING=true
        fi

        AUTHOR_USER=$(get_github_user "$AUTHOR_NAME" "$AUTHOR_EMAIL")
        release_add_commit "$TYPE" "$SCOPE" "$DESC" "$PR" "$AUTHOR_USER"

        TOTAL=$((TOTAL + 1))
    done <<< "$LOG"

    if [[ $TOTAL -eq 0 ]]; then
        echo -e "\033[33mNo conventional commits found since last release.\033[0m"
        exit 0
    fi

    if [[ -n "$LAST_TAG" ]]; then
        CURRENT_VERSION="${LAST_TAG#v}"
    else
        CURRENT_VERSION="0.1.0"
    fi

    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

    if [[ -n "$version_override" ]]; then
        NEW_VERSION="${version_override#v}"
    elif [[ "$force_type" == "major" ]]; then
        NEW_VERSION="$((MAJOR + 1)).0.0"
    elif [[ "$force_type" == "minor" ]]; then
        NEW_VERSION="${MAJOR}.$((MINOR + 1)).0"
    elif [[ "$force_type" == "patch" ]]; then
        NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
    elif [[ "$HAS_BREAKING" == true ]]; then
        NEW_VERSION="$((MAJOR + 1)).0.0"
    elif echo "$LOG" | grep -qE '\|feat[(:]'; then
        NEW_VERSION="${MAJOR}.$((MINOR + 1)).0"
    else
        NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
    fi

    TAG_NAME="v$NEW_VERSION"

    if git rev-parse --verify "refs/tags/$TAG_NAME" >/dev/null 2>&1; then
        echo -e "\033[31mTag $TAG_NAME already exists.\033[0m"
        exit 1
    fi

    TODAY=$(date +%Y-%m-%d)

    NOTES=$(build_release_notes)

    SECTION="## [$NEW_VERSION]($TODAY)"
    SECTION+=$'\n'$'\n'
    SECTION+="$NOTES"

    CHANGELOG_FILE="CHANGELOG.md"
    TMP_CONTENT=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/gitwhisper-release.txt")

    if [[ -f "$CHANGELOG_FILE" ]] && grep -q '^## \[' "$CHANGELOG_FILE" 2>/dev/null; then
        FIRST_LINE=$(grep -n '^## \[' "$CHANGELOG_FILE" | head -1 | cut -d: -f1)
        {
            head -n $((FIRST_LINE - 1)) "$CHANGELOG_FILE"
            echo "$SECTION"
            echo ""
            tail -n +"$FIRST_LINE" "$CHANGELOG_FILE"
        } > "$TMP_CONTENT"
    else
        {
            echo "# Changelog"
            echo ""
            echo "All notable changes to this project will be documented in this file."
            echo ""
            echo "Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)"
            echo ""
            echo "$SECTION"
        } > "$TMP_CONTENT"
    fi

    echo ""
    echo -e "\033[32m=== Release preview ===\033[0m"
    echo ""
    echo -e "  Version:  \033[36m$NEW_VERSION\033[0m"
    echo -e "  Commits:  \033[36m$TOTAL\033[0m"
    echo -e "  Breaking: \033[36m$HAS_BREAKING\033[0m"
    echo ""
    echo -e "\033[36m=== Changelog section ===\033[0m"
    echo ""
    echo "$SECTION" | while IFS= read -r line; do
        echo "  $line"
    done

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo -e "  \033[90m[DRY-RUN] Release skipped. No changes made.\033[0m"
        rm -f "$TMP_CONTENT"
        exit 0
    fi

    echo ""
    read -p "  Proceed with release v$NEW_VERSION? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo ""
        echo -e "  \033[33mCancelled.\033[0m"
        rm -f "$TMP_CONTENT"
        exit 0
    fi

    echo ""
    echo -e "  \033[36mWriting CHANGELOG.md...\033[0m"
    mv "$TMP_CONTENT" "$CHANGELOG_FILE"
    git add "$CHANGELOG_FILE"

    COMMIT_FILE=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/gitwhisper-commit.txt")
    printf 'chore(release): %s\n\n%s\n' "$TAG_NAME" "$NOTES" > "$COMMIT_FILE"
    git commit -F "$COMMIT_FILE" >/dev/null || { rm -f "$COMMIT_FILE"; echo -e "  \033[31mRelease commit failed.\033[0m"; exit 1; }
    rm -f "$COMMIT_FILE"

    HEAD_SHORT=$(git rev-parse --short HEAD)

    echo -e "  \033[36mCreating tag $TAG_NAME...\033[0m"
    TAG_FILE=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/gitwhisper-tag.txt")
    printf '%s\n\n%s\n' "$HEAD_SHORT" "$NOTES" > "$TAG_FILE"
    git tag -a "$TAG_NAME" -F "$TAG_FILE" || { rm -f "$TAG_FILE"; echo -e "  \033[31mTag creation failed.\033[0m"; exit 1; }
    rm -f "$TAG_FILE"

    echo ""
    echo -e "  \033[32mRelease $TAG_NAME created!\033[0m"

    if [[ "$push" == true ]]; then
        PUSH_CHOICE="y"
    else
        read -p "  Push commit and tag? (y/n): " PUSH_CHOICE
    fi
    if [[ "$PUSH_CHOICE" == "y" || "$PUSH_CHOICE" == "Y" ]]; then
        echo ""
        echo -e "  \033[36mPushing...\033[0m"
        git push >/dev/null || { echo -e "  \033[31mPush failed.\033[0m"; exit 1; }
        git push origin "$TAG_NAME" >/dev/null || { echo -e "  \033[31mTag push failed.\033[0m"; exit 1; }
        echo -e "  \033[32mPushed successfully!\033[0m"
    fi

    if command -v gh >/dev/null 2>&1; then
        if [[ "$github_flag" == true || "$push" == true ]]; then
            GH_CHOICE="y"
        else
            echo ""
            read -p "  Publish GitHub Release? (y/n): " GH_CHOICE
        fi
        if [[ "$GH_CHOICE" == "y" || "$GH_CHOICE" == "Y" ]]; then
            echo ""
            echo -e "  \033[36mPublishing GitHub Release $TAG_NAME...\033[0m"
            NOTES_FILE=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/gitwhisper-notes.txt")
            printf '%s\n\n%s\n' "$HEAD_SHORT" "$NOTES" > "$NOTES_FILE"
            gh release create "$TAG_NAME" --title "$TAG_NAME" --notes-file "$NOTES_FILE" \
                || echo -e "  \033[31mGitHub Release failed.\033[0m"
            rm -f "$NOTES_FILE"
        fi
    elif [[ "$github_flag" == true ]]; then
        echo ""
        echo -e "  \033[33mgh CLI not found. Install it to publish GitHub Releases.\033[0m"
    fi
}

declare -A GW_CONFIG

load_gw_config

if [[ -n "${GW_CONFIG[general.core_maintainers]}" ]]; then
    IFS=',' read -ra _maint <<< "${GW_CONFIG[general.core_maintainers]}"
    CORE_MAINTAINERS=()
    for _u in "${_maint[@]}"; do
        _u=$(echo "$_u" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$_u" ]] && CORE_MAINTAINERS+=("$_u")
    done
fi

case "$CMD" in
    ""|commit)
        invoke_commit
        ;;
    undo)
        invoke_undo
        ;;
    amend)
        invoke_amend
        ;;
    changelog)
        invoke_changelog "$@"
        ;;
    pr)
        invoke_pr "$@"
        ;;
    release)
        invoke_release "$@"
        ;;
    init)
        invoke_init "$@"
        ;;
    suggest)
        invoke_suggest
        ;;
    *)
        echo "Unknown command: $CMD"
        show_help
        ;;
esac
