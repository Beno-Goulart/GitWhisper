# GitWhisper `undo` command (Bash).

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
