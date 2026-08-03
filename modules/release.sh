# GitWhisper `release` command (Bash).

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
