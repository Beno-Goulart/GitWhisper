#!/bin/bash

# GitWhisper Changelog Generator
# Usage: ./changelog.sh [--since-tag] [--limit 50]

SINCE_TAG=false
LIMIT=50

while [[ $# -gt 0 ]]; do
    case $1 in
        --since-tag) SINCE_TAG=true; shift ;;
        --limit) LIMIT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Check if git repo
if [[ ! -d ".git" ]]; then
    echo -e "\033[31mError: Not a git repository.\033[0m"
    exit 1
fi

# Get commits
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

# Declare arrays for each type
declare -a FEAT=() FIX=() PERF=() REFACTOR=() DOCS=() TEST=()
declare -a BUILD=() CI=() CHORE=() STYLE=() REVERT=() OTHER=()

TOTAL=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    
    HASH=$(echo "$line" | cut -d'|' -f1)
    MESSAGE=$(echo "$line" | cut -d'|' -f2)
    DATE=$(echo "$line" | cut -d'|' -f3)
    
    SHORT_HASH="${HASH:0:7}"
    
    # Parse type (handle gitmoji prefix like ♻ refactor: ...)
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

# Get version
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null)
if [[ $? -eq 0 && -n "$LAST_TAG" ]]; then
    CURRENT_VERSION="${LAST_TAG#v}"
else
    CURRENT_VERSION="0.1.0"
fi

# Determine bump
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

# Build changelog
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
