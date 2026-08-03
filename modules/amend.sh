# GitWhisper `amend` command (Bash).

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
