#!/bin/bash
set -euo pipefail

PROJECT="Preview3MF.xcodeproj/project.pbxproj"
SCHEME="Preview3MF"
PRODUCT="Preview3MF"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PBXPROJ="$SCRIPT_DIR/$PROJECT"

# ── Parse arguments ──────────────────────────────────────────────────────────
BUMP="patch"   # default
DRY_RUN=false

usage() {
    echo "Usage: $0 [--patch | --minor | --major] [--dry-run]"
    echo ""
    echo "  --patch   (default) 1.0.0 → 1.0.1"
    echo "  --minor              1.0.1 → 1.1.0"
    echo "  --major              1.1.0 → 2.0.0"
    echo "  --dry-run            Show what would happen without making changes"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --patch) BUMP="patch" ;;
        --minor) BUMP="minor" ;;
        --major) BUMP="major" ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $arg"; usage ;;
    esac
done

# ── Read current version ─────────────────────────────────────────────────────
CURRENT_MARKETING=$(grep -m1 'MARKETING_VERSION' "$PBXPROJ" | sed 's/.*= *//;s/ *;.*//')
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | sed 's/.*= *//;s/ *;.*//')

# Normalise to 3 components (e.g. "1.0" → "1.0.0")
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_MARKETING"
MAJOR=${MAJOR:-0}
MINOR=${MINOR:-0}
PATCH=${PATCH:-0}

# ── Compute new version ──────────────────────────────────────────────────────
case "$BUMP" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
NEW_BUILD=$((CURRENT_BUILD + 1))
TAG="v$NEW_VERSION"

echo "──────────────────────────────────────"
echo "  Version : $CURRENT_MARKETING → $NEW_VERSION"
echo "  Build   : $CURRENT_BUILD → $NEW_BUILD"
echo "  Tag     : $TAG"
echo "  Bump    : $BUMP"
echo "──────────────────────────────────────"

if $DRY_RUN; then
    echo "(dry run — exiting)"
    exit 0
fi

# ── Ensure clean working tree (aside from this script itself) ────────────────
if ! git -C "$SCRIPT_DIR" diff --quiet -- . ':!release.sh' || \
   ! git -C "$SCRIPT_DIR" diff --cached --quiet; then
    echo "Error: You have uncommitted changes. Please commit or stash them first."
    exit 1
fi

# ── Bump versions in pbxproj ─────────────────────────────────────────────────
sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $NEW_VERSION;/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ"

echo "✓ Updated pbxproj"

# ── Commit & tag ─────────────────────────────────────────────────────────────
git -C "$SCRIPT_DIR" add "$PBXPROJ"
git -C "$SCRIPT_DIR" commit -m "Bump version to $NEW_VERSION (build $NEW_BUILD)"
git -C "$SCRIPT_DIR" tag -a "$TAG" -m "Release $TAG"

echo "✓ Committed and tagged $TAG"

# ── Push ─────────────────────────────────────────────────────────────────────
git -C "$SCRIPT_DIR" push origin main
git -C "$SCRIPT_DIR" push origin "$TAG"

echo "✓ Pushed to origin"

# ── Build Release .app ───────────────────────────────────────────────────────
BUILD_DIR="$SCRIPT_DIR/build"
rm -rf "$BUILD_DIR"

echo "Building $SCHEME (Release)..."
xcodebuild \
    -project "$SCRIPT_DIR/$( echo "$PROJECT" | sed 's|/.*||' )" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -arch "$(uname -m)" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    ONLY_ACTIVE_ARCH=YES \
    -quiet

APP_PATH=$(find "$BUILD_DIR/DerivedData" -name "$PRODUCT.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "Error: Could not find $PRODUCT.app in build output"
    exit 1
fi

echo "✓ Built $APP_PATH"

# ── Zip the .app ─────────────────────────────────────────────────────────────
ZIP_NAME="$PRODUCT-$TAG-$(uname -m).zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "✓ Zipped to $ZIP_PATH"

# ── Create GitHub Release ────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
    echo ""
    echo "⚠ gh CLI not found — skipping GitHub Release creation."
    echo "  Install it (brew install gh) then run:"
    echo "  gh release create $TAG $ZIP_PATH --title \"$TAG\" --generate-notes"
    exit 0
fi

gh release create "$TAG" "$ZIP_PATH" \
    --title "$TAG" \
    --generate-notes

REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin | sed 's/\.git$//;s|git@github.com:|https://github.com/|')
echo ""
echo "✓ Release $TAG created!"
echo "  $REPO_URL/releases/tag/$TAG"
