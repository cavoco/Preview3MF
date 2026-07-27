#!/bin/bash
# Re-sign Sparkle's nested helpers with the Developer ID identity.
#
# When Sparkle is embedded from SPM, Xcode signs Sparkle.framework itself but
# leaves the helpers *inside* it (Updater.app, Autoupdate, and the two XPC
# services) carrying Sparkle's own ad-hoc signatures. Notarization rejects any
# ad-hoc signed executable, so they have to be re-signed here.
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

# Fail loudly if anything under the app is still ad-hoc signed, rather than
# letting notarization discover it several minutes later. Matching on the string
# rather than piping into grep keeps `set -o pipefail` from tripping on SIGPIPE.
STATUS=0
for target in \
    "$VERSIONS/XPCServices/Downloader.xpc" \
    "$VERSIONS/XPCServices/Installer.xpc" \
    "$VERSIONS/Updater.app" \
    "$VERSIONS/Autoupdate" \
    "$FRAMEWORK" \
    "$APP"; do
    DETAILS=$(codesign -dvv "$target" 2>&1 || true)
    if [[ "$DETAILS" != *"Authority=Developer ID Application"* ]]; then
        echo "error: $target is not signed with a Developer ID Application certificate" >&2
        STATUS=1
    fi
done

if [ $STATUS -eq 0 ]; then
    echo "Sparkle helpers signed with $IDENTITY"
fi
exit $STATUS
