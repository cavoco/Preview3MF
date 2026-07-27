#!/bin/bash
# Print the user-facing commit subjects between two refs, one per line.
#
# These lines end up in Sparkle's update dialog, so commits that changed only the
# landing page, README, CI config or release plumbing are dropped — they describe
# nothing a user of the app would notice. Version bumps go too.
#
# Usage: release_notes.sh <previous-ref> <current-ref>
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <previous-ref> <current-ref>" >&2
    exit 1
fi

PREVIOUS="$1"
CURRENT="$2"

# Paths that never justify a line in an update dialog on their own.
IGNORED='^(docs/|scripts/|\.github/|README\.md$|LICENSE$|\.gitignore$)|^$'

# tformat: (not format:) terminates every line, including the last. With format:
# the oldest commit arrives without a trailing newline and `read` drops it at EOF.
git log --pretty=tformat:'%H %s' "${PREVIOUS}..${CURRENT}" | while IFS=' ' read -r sha subject; do
    case "$subject" in
        "Bump version"*) continue ;;
    esac

    # Keep the commit only if it touched at least one path outside IGNORED.
    if git show --pretty=format: --name-only "$sha" | grep -qvE "$IGNORED"; then
        echo "$subject"
    fi
done
