#!/usr/bin/env bash
# Builds, signs and publishes a Sidekick release to GitHub, and updates the Sparkle feed.
# Usage: scripts/release.sh <version> [notes]     e.g. scripts/release.sh 0.1.1 "Faster polish"
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="xanderlzy/sidekick"
VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-Sidekick $VERSION}"
IDENTITY="Sidekick Self-Signed"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3"; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Commit or stash your changes first."; exit 1; }
if git rev-parse "v$VERSION" >/dev/null 2>&1; then echo "Tag v$VERSION already exists."; exit 1; fi
security find-certificate -c "$IDENTITY" >/dev/null || { echo "Run scripts/make-cert.sh first."; exit 1; }

# 1. Bump version and build number.
BUILD=$(( $(sed -nE 's/.*CURRENT_PROJECT_VERSION: "([0-9]+)".*/\1/p' project.yml) + 1 ))
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen -q

# 2. Archive a signed Release build.
DIST="dist/$VERSION"
mkdir -p "$DIST"
echo "Building Sidekick $VERSION ($BUILD)…"
xcodebuild -scheme Sidekick -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$DIST/Sidekick.xcarchive" archive > "$DIST/build.log" 2>&1 \
  || { tail -20 "$DIST/build.log"; exit 1; }
APP="$DIST/Sidekick.xcarchive/Products/Applications/Sidekick.app"
codesign --verify --deep --strict "$APP"

# 3. Zip and sign the update for Sparkle.
ZIP="$DIST/Sidekick-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SPARKLE_BIN=$(ls -d ~/Library/Developer/Xcode/DerivedData/Sidekick-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account sidekick "$ZIP")

# 4. Prepend this release to the appcast.
URL="https://github.com/$REPO/releases/download/v$VERSION/Sidekick-$VERSION.zip"
python3 - "$VERSION" "$BUILD" "$URL" "$SIGNATURE" "$NOTES" <<'PY'
import sys, html, email.utils
version, build, url, signature, notes = sys.argv[1:]
item = f"""    <item>
      <title>Sidekick {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>{html.escape(notes)}</p>]]></description>
      <enclosure url="{url}" {signature} type="application/octet-stream"/>
    </item>
"""
path = "appcast.xml"
text = open(path).read()
marker = "<language>en</language>\n"
open(path, "w").write(text.replace(marker, marker + item, 1))
PY

# 5. Commit, tag, push, publish.
git add project.yml appcast.xml Sidekick.xcodeproj
git commit -qm "release: v$VERSION"
git tag "v$VERSION"
git push -q origin HEAD --tags
gh release create "v$VERSION" "$ZIP" appcast.xml --repo "$REPO" --title "Sidekick $VERSION" --notes "$NOTES"
echo "Released Sidekick $VERSION → https://github.com/$REPO/releases/tag/v$VERSION"
