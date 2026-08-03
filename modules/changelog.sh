# GitWhisper `changelog` command (Bash).

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
