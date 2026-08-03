# GitWhisper shared library (Bash).
# Sourced by gitwhisper.sh. Contains shared state and helpers used by
# more than one command module (commit/suggest and changelog/release).

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

declare -A GW_CONFIG

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
        if [[ "$f" =~ gitwhisper|modules/|^install\.(ps1|sh)$ ]]; then
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
