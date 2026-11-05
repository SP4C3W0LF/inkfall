#!/usr/bin/env bash
#
# Build, sign, notarize and package Inkfall as a drag-to-Applications DMG.
# Run by .github/workflows/release.yml on a GitHub-hosted macOS runner; also runs on any
# Mac with Xcode, xcodegen and create-dmg.
#
# Usage: ci/release.sh <version> [--dry-run]
#   --dry-run  archive + unsigned DMG only: no signing, no notarization. Needs no secrets.
#
# Real releases read these from the environment (GitHub "release" environment secrets):
#   DEVELOPER_ID_P12           base64 of a .p12 holding the "Developer ID Application" identity
#   DEVELOPER_ID_P12_PASSWORD  its export password
#   NOTARY_KEY_P8              App Store Connect API key (.p8 contents) used by notarytool
#   NOTARY_KEY_ID              its key id
#   NOTARY_ISSUER_ID           its issuer id
# Nothing secret is written to the repo or printed; the temporary keychain is deleted on exit.
#
# Output: dist/Inkfall.dmg (release) or dist/Inkfall-dryrun.dmg (dry run).
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [--dry-run]}"
MODE="${2:-release}"
TEAM_ID="8K757QX5LK"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
cd "$ROOT"
mkdir -p "$DIST"

for tool in xcodegen xcodebuild; do
  command -v "$tool" >/dev/null || { echo "✗ $tool not found" >&2; exit 1; }
done
echo "▸ Toolchain: $(xcodebuild -version | head -1)"

# Signing overlay: the team id is public (it is in every signed binary); keep it out of
# project.yml so a contributor's local build doesn't try to sign as Andre.
cat > "$ROOT/project.release.yml" <<YML
include:
  - project.yml
targets:
  Inkfall:
    settings:
      base:
        DEVELOPMENT_TEAM: "$TEAM_ID"
YML
echo "▸ Generating Xcode project…"
xcodegen generate --spec "$ROOT/project.release.yml" --project "$ROOT"

SIGN_ARGS=()
KC=""
cleanup() {
  [[ -n "$KC" ]] && security delete-keychain "$KC" >/dev/null 2>&1 || true
  rm -f "$ROOT/project.release.yml"
}
trap cleanup EXIT

if [[ "$MODE" == "--dry-run" ]]; then
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
else
  for v in DEVELOPER_ID_P12 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID; do
    [[ -n "${!v:-}" ]] || { echo "✗ $v is not set (GitHub 'release' environment secret)" >&2; exit 1; }
  done
  command -v create-dmg >/dev/null || { echo "✗ create-dmg missing (brew install create-dmg)" >&2; exit 1; }
  echo "▸ Creating a temporary signing keychain…"
  KC="${RUNNER_TEMP:-$(mktemp -d)}/inkfall-signing.keychain-db"
  KC_PW="$(openssl rand -base64 24)"
  P12="$(mktemp -d)/devid.p12"
  printf '%s' "$DEVELOPER_ID_P12" | base64 --decode > "$P12"
  security create-keychain -p "$KC_PW" "$KC"
  security set-keychain-settings -lut 3600 "$KC"
  security unlock-keychain -p "$KC_PW" "$KC"
  security import "$P12" -k "$KC" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  rm -f "$P12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PW" "$KC" >/dev/null
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  security find-identity -v -p codesigning "$KC" | grep -q "Developer ID Application" \
    || { echo "✗ no Developer ID Application identity in the .p12" >&2; exit 1; }
  # Manual style: Developer ID apps need no provisioning profile, and Automatic conflicts with it.
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--keychain=$KC")
fi

echo "▸ Archiving Inkfall ${VERSION}…"
rm -rf "$DIST/Inkfall.xcarchive" "$DIST/export"
xcodebuild -project "$ROOT/Inkfall.xcodeproj" -scheme Inkfall -configuration Release \
  -archivePath "$DIST/Inkfall.xcarchive" MARKETING_VERSION="$VERSION" "${SIGN_ARGS[@]}" archive

if [[ "$MODE" == "--dry-run" ]]; then
  echo "▸ Dry run: unsigned DMG, no notarization…"
  hdiutil create -volname Inkfall -srcfolder "$DIST/Inkfall.xcarchive/Products/Applications/Inkfall.app" \
    -ov -format UDZO "$DIST/Inkfall-dryrun.dmg"
  echo "✅ DRY RUN OK: $DIST/Inkfall-dryrun.dmg"
  exit 0
fi

echo "▸ Exporting the Developer ID–signed app…"
xcodebuild -exportArchive -archivePath "$DIST/Inkfall.xcarchive" \
  -exportOptionsPlist "$ROOT/ci/exportOptions.plist" -exportPath "$DIST/export"

APP="$DIST/export/Inkfall.app"
DMG="$DIST/Inkfall.dmg"
rm -f "$DMG"
echo "▸ Building the drag-to-Applications DMG…"
# create-dmg sometimes exits non-zero after producing a good image (an AppleScript layout
# hiccup), so tolerate the exit code and check the file.
create-dmg --volname Inkfall --window-size 500 320 --icon-size 100 \
  --icon Inkfall.app 130 160 --app-drop-link 370 160 --no-internet-enable \
  "$DMG" "$APP" || true
[[ -f "$DMG" ]] || { echo "✗ DMG was not created" >&2; exit 1; }

codesign --force --sign "Developer ID Application" --keychain "$KC" "$DMG"
echo "▸ Notarizing (uploads to Apple and waits)…"
NOTARY_KEY="$(mktemp -d)/notary.p8"
printf '%s' "$NOTARY_KEY_P8" > "$NOTARY_KEY"
xcrun notarytool submit "$DMG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" --wait
rm -f "$NOTARY_KEY"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "✅ Release artifact ready: $DMG"
