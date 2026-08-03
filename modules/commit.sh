# GitWhisper `commit` command (Bash).

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
