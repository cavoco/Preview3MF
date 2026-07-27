#!/bin/bash
# Re-sign Sparkle's nested helpers with the app's signing identity.
#
# When Sparkle is embedded from SPM, Xcode signs Sparkle.framework itself but
# leaves the helpers *inside* it (Updater.app, Autoupdate, and the two XPC
# services) carrying Sparkle's own ad-hoc signatures. That breaks two things:
# notarization rejects ad-hoc signed executables, and Sparkle refuses to use
# helpers whose team identifier doesn't match the host app's — which surfaces
# to the user as "An error occurred in retrieving update information".
#
# The release workflow runs this after building. It is deliberately NOT an Xcode
# build phase: the project sets ENABLE_USER_SCRIPT_SANDBOXING, under which
# codesign cannot touch the app bundle, and the phase fails *silently*. So a
# build straight from Xcode leaves the helpers ad-hoc and cannot test updates —
# run this by hand afterwards if you need to:
#
#   ./scripts/sign_sparkle.sh <path-to-.app> "$(security find-identity -v -p codesigning \
#       | grep 'Apple Development' | head -1 | awk -F'"' '{print $2}')"
#
# Signing runs inside-out: every signature seals the code beneath it, so the
# framework and then the app must be re-sealed after their contents change.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <path-to-.app> <signing-identity> [entitlements-plist]" >&2
    exit 1
fi

APP="$1"
IDENTITY="$2"
ENTITLEMENTS="${3:-}"

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$FRAMEWORK" ]; then
    echo "error: no Sparkle.framework inside $APP" >&2
    exit 1
fi

VERSIONS="$FRAMEWORK/Versions/B"

sign() {
    codesign --force --sign "$IDENTITY" --timestamp --options runtime "$@"
}

sign "$VERSIONS/XPCServices/Downloader.xpc"
sign "$VERSIONS/XPCServices/Installer.xpc"
sign "$VERSIONS/Updater.app"
sign "$VERSIONS/Autoupdate"
sign "$FRAMEWORK"

if [ -n "$ENTITLEMENTS" ]; then
    sign --entitlements "$ENTITLEMENTS" "$APP"
else
    sign "$APP"
fi

# Verify against the app's own team identifier rather than a specific certificate,
# so this holds for both Developer ID (release) and Apple Development (local)
# builds. Matching on the string rather than piping into grep keeps
# `set -o pipefail` from tripping on SIGPIPE.
team_of() {
    local details
    details=$(codesign -dvv "$1" 2>&1 || true)
    printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p' | head -1
}

APP_TEAM=$(team_of "$APP")
if [ -z "$APP_TEAM" ] || [ "$APP_TEAM" = "not set" ]; then
    echo "error: $APP has no team identifier after signing" >&2
    exit 1
fi

STATUS=0
for target in \
    "$VERSIONS/XPCServices/Downloader.xpc" \
    "$VERSIONS/XPCServices/Installer.xpc" \
    "$VERSIONS/Updater.app" \
    "$VERSIONS/Autoupdate" \
    "$FRAMEWORK"; do
    TEAM=$(team_of "$target")
    if [ "$TEAM" != "$APP_TEAM" ]; then
        echo "error: $target has team '${TEAM:-none}', expected '$APP_TEAM'" >&2
        STATUS=1
    fi
done

if [ $STATUS -eq 0 ]; then
    echo "Sparkle helpers signed for team $APP_TEAM"
fi
exit $STATUS
