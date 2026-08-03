# GitWhisper `suggest` command (Bash).
# Used by the smart hooks to pre-fill a suggested message.

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
