#!/usr/bin/env bash

set -e

# GitWhisper entry point. Sources the shared library and command modules
# from ./modules and dispatches to the requested command.

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SOURCE_DIR/modules/lib.sh"
source "$SOURCE_DIR/modules/help.sh"
source "$SOURCE_DIR/modules/undo.sh"
source "$SOURCE_DIR/modules/amend.sh"
source "$SOURCE_DIR/modules/commit.sh"
source "$SOURCE_DIR/modules/suggest.sh"
source "$SOURCE_DIR/modules/init.sh"
source "$SOURCE_DIR/modules/pr.sh"
source "$SOURCE_DIR/modules/changelog.sh"
source "$SOURCE_DIR/modules/release.sh"

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

load_gw_config

if [[ -n "${GW_CONFIG[general.core_maintainers]}" ]]; then
    IFS=',' read -ra _maint <<< "${GW_CONFIG[general.core_maintainers]}"
    CORE_MAINTAINERS=()
    for _u in "${_maint[@]}"; do
        _u=$(echo "$_u" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$_u" ]] && CORE_MAINTAINERS+=("$_u")
    done
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
    release)
        invoke_release "$@"
        ;;
    init)
        invoke_init "$@"
        ;;
    suggest)
        invoke_suggest
        ;;
    *)
        echo "Unknown command: $CMD"
        show_help
        ;;
esac
