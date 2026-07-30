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
    echo "    gitwhisper help          - show this help"
    echo "    gitwhisper pr            - generate PR description"
    echo "    gitwhisper pr --base main   - specify base branch"
    echo "    gitwhisper --dry-run     - show message without committing"
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
    *)
        echo "Unknown command: $CMD"
        show_help
        ;;
esac

invoke_undo() {
    LAST_MSG=$(git log -1 --format="%s" 2>/dev/null)
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
    LAST_MSG=$(git log -1 --format="%s" 2>/dev/null)
    LAST_BODY=$(git log -1 --format="%b" 2>/dev/null)
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
                ((count++))
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

    ADDED_LINES=$(echo "$DIFF_CONTENT" | grep -E '^\+[^+]' || true)
    REMOVED_LINES=$(echo "$DIFF_CONTENT" | grep -E '^-[^-]' || true)

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

    HAS_PERF=false
    IS_SCRIPT=false
    for f in "${ALL_CHANGED_LOWER[@]}"; do
        if [[ "$f" =~ (gitwhisper|\.sh$|\.ps1$|\.py$|\.rb$|\.js$|\.ts$) ]]; then
            IS_SCRIPT=true
            break
        fi
    done

    if [[ "$DIFF_CONTENT" =~ (perf|optim|cache|lazy|memo|defer|throttle|debounce|batch|index) ]]; then
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
        SPECIFIC_DESC="${SPECIFIC_DESC:4}"
    fi

    COMMIT_TYPE=""
    COMMIT_DESC=""

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
    elif [[ $CONFIG_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 && $DOC_COUNT -eq 0 && $CI_COUNT -eq 0 ]]; then
        COMMIT_TYPE="build"
        COMMIT_DESC="updates configuration"
    elif [[ $CI_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 ]]; then
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
    elif [[ $DB_COUNT -gt 0 && $NON_TEST_COUNT -eq 0 ]]; then
        COMMIT_TYPE="db"
        COMMIT_DESC="updates database schema"
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

    echo ""
    echo -e "  \033[36mBody:\033[0m"
    for bl in "${BODY_PARTS[@]}"; do
        echo "    $bl"
    done
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  \033[90m[DRY-RUN] Commit skipped.\033[0m"
        return
    fi

    BODY=$(printf '%s\n' "${BODY_PARTS[@]}")
    FULL_MSG="$SELECTED_MSG"$'\n'"$BODY"
    TEMP_FILE=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/gitwhisper-msg.txt")
    echo "$FULL_MSG" > "$TEMP_FILE"

    echo ""
    read -p "  Open editor to review? (y/n): " EDIT_MSG
    if [[ "$EDIT_MSG" == "y" || "$EDIT_MSG" == "Y" ]]; then
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
        LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null)
        if [[ $? -eq 0 && -n "$LAST_TAG" ]]; then
            LOG=$(git log "$LAST_TAG..HEAD" --pretty=format:"%H|%s|%ad" --date=short)
        else
            echo -e "\033[33mNo tags found. Showing all commits.\033[0m"
            LOG=$(git log --pretty=format:"%H|%s|%ad" --date=short -n "$LIMIT")
        fi
    else
        LOG=$(git log --pretty=format:"%H|%s|%ad" --date=short -n "$LIMIT")
    fi

    if [[ -z "$LOG" ]]; then
        echo -e "\033[33mNo commits found.\033[0m"
        exit 0
    fi

    declare -a FEAT=() FIX=() PERF=() REFACTOR=() DOCS=() TEST=()
    declare -a BUILD=() CI=() CHORE=() STYLE=() REVERT=() OTHER=()

    TOTAL=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        HASH=$(echo "$line" | cut -d'|' -f1)
        MESSAGE=$(echo "$line" | cut -d'|' -f2)
        DATE=$(echo "$line" | cut -d'|' -f3)

        SHORT_HASH="${HASH:0:7}"

        TYPE=$(echo "$MESSAGE" | grep -oE '[a-z]+\(' | head -1 | tr -d '(')
        if [[ -z "$TYPE" ]]; then
            TYPE=$(echo "$MESSAGE" | grep -oE '[a-z]+:' | head -1 | tr -d ':')
        fi
        SCOPE=$(echo "$MESSAGE" | grep -oE '\([^)]+\)' | tr -d '()')
        DESC=$(echo "$MESSAGE" | sed 's/.*:[[:space:]]*//')

        COMMIT_ENTRY="- "
        if [[ -n "$SCOPE" ]]; then
            COMMIT_ENTRY+="**${SCOPE}:** "
        fi
        COMMIT_ENTRY+="${DESC} (\`${SHORT_HASH}\`)"

        case "$TYPE" in
            feat)     FEAT+=("$COMMIT_ENTRY") ;;
            fix)      FIX+=("$COMMIT_ENTRY") ;;
            perf)     PERF+=("$COMMIT_ENTRY") ;;
            refactor) REFACTOR+=("$COMMIT_ENTRY") ;;
            docs)     DOCS+=("$COMMIT_ENTRY") ;;
            test)     TEST+=("$COMMIT_ENTRY") ;;
            build)    BUILD+=("$COMMIT_ENTRY") ;;
            ci)       CI+=("$COMMIT_ENTRY") ;;
            chore)    CHORE+=("$COMMIT_ENTRY") ;;
            style)    STYLE+=("$COMMIT_ENTRY") ;;
            revert)   REVERT+=("$COMMIT_ENTRY") ;;
            *)        OTHER+=("$COMMIT_ENTRY") ;;
        esac

        ((TOTAL++))
    done <<< "$LOG"

    if [[ $TOTAL -eq 0 ]]; then
        echo -e "\033[33mNo conventional commits found.\033[0m"
        exit 0
    fi

    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null)
    if [[ $? -eq 0 && -n "$LAST_TAG" ]]; then
        CURRENT_VERSION="${LAST_TAG#v}"
    else
        CURRENT_VERSION="0.1.0"
    fi

    HAS_FEAT=$((${#FEAT[@]}))
    HAS_FIX=$((${#FIX[@]}))
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

    {
    echo "# Changelog"
    echo ""
    echo "All notable changes to this project will be documented in this file."
    echo ""
    echo "Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)"
    echo ""
    echo "## [$NEW_VERSION]($TODAY)"
    echo ""

    write_section() {
        local title="$1"
        shift
        local arr=("$@")
        if [[ ${#arr[@]} -gt 0 ]]; then
            echo "### $title"
            echo ""
            for entry in "${arr[@]}"; do
                echo "$entry"
            done
            echo ""
        fi
    }

    write_section "Features" "${FEAT[@]}"
    write_section "Bug Fixes" "${FIX[@]}"
    write_section "Performance" "${PERF[@]}"
    write_section "Refactoring" "${REFACTOR[@]}"
    write_section "Documentation" "${DOCS[@]}"
    write_section "Tests" "${TEST[@]}"
    write_section "Build" "${BUILD[@]}"
    write_section "CI/CD" "${CI[@]}"
    write_section "Chores" "${CHORE[@]}"
    write_section "Style" "${STYLE[@]}"
    write_section "Reverts" "${REVERT[@]}"
    write_section "Other" "${OTHER[@]}"

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

    LOG=$(git log "$MERGE_BASE..$BRANCH" --pretty=format:"%H|%s|%ad" --date=short --no-merges 2>/dev/null)
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
        SCOPE=$(echo "$MESSAGE" | grep -oE '\([^)]+\)' | tr -d '()')
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
        ((TOTAL++))
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
