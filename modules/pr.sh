# GitWhisper `pr` command (Bash).

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
    declare -A CUSTOM_GROUPS=() CUSTOM_TITLES=() CUSTOM_EMOJI=()
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
            *)
                if [[ -n "${TYPE_TITLES[$TYPE]:-}${GW_TYPE_EMOJI[$TYPE]:-}" ]]; then
                    CUSTOM_GROUPS["$TYPE"]+="$ENTRY"$'\n'
                    CUSTOM_TITLES["$TYPE"]="${TYPE_TITLES[$TYPE]:-$TYPE}"
                    [[ -z "${CUSTOM_EMOJI[$TYPE]:-}" ]] && CUSTOM_EMOJI["$TYPE"]="${GW_TYPE_EMOJI[$TYPE]:-🔨}"
                else
                    OTHER+=("$ENTRY")
                fi
                ;;
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

    for _ct in "${!CUSTOM_GROUPS[@]}"; do
        PR_BODY+=$'\n'"### ${CUSTOM_TITLES[$_ct]}"
        PR_BODY+=$'\n'""
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && PR_BODY+=$'\n'"${CUSTOM_EMOJI[$_ct]} $entry"
        done <<< "${CUSTOM_GROUPS[$_ct]%$'\n'}"
        PR_BODY+=$'\n'""
    done

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
