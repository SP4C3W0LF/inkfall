#!/usr/bin/env bash
#
# One-time: put Inkfall's signing + notarization secrets into the GitHub "release"
# environment. Run it YOURSELF in Terminal on the Mac that holds the Developer ID
# identity. Values go straight from this Mac to GitHub; nothing is printed or saved.
#
#   ci/set-release-secrets.sh
#
# Needs: gh logged in as the repo owner, and the inkfall-ci keychain from the old setup
# (or set KEYCHAIN=~/Library/Keychains/login.keychain-db to export from login instead).
set -euo pipefail
REPO="SP4C3W0LF/inkfall"; ENV_NAME="release"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/inkfall-ci.keychain-db}"
KC_PW_FILE="$HOME/inkfall-release/ci-keychain-password"

security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "Developer ID Application" \
  || { echo "✗ no Developer ID Application identity in $KEYCHAIN" >&2; exit 1; }
[[ -f "$KC_PW_FILE" ]] && security unlock-keychain -p "$(cat "$KC_PW_FILE")" "$KEYCHAIN"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
P12PW="$(openssl rand -base64 24)"
echo "▸ Exporting the signing identity (macOS may ask you to allow it)…"
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$P12PW" -o "$TMP/devid.p12"
base64 -i "$TMP/devid.p12" | gh secret set DEVELOPER_ID_P12 --repo "$REPO" --env "$ENV_NAME"
printf '%s' "$P12PW" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$REPO" --env "$ENV_NAME"

echo ""
echo "Notarization needs an app-specific password: account.apple.com ▸ Sign-In and Security"
echo "▸ App-Specific Passwords ▸ +  (name it e.g. inkfall-github)."
read -rp "Apple ID email: " APPLE_ID
read -rsp "App-specific password (hidden): " ASP; echo ""
printf '%s' "$APPLE_ID" | gh secret set NOTARY_APPLE_ID --repo "$REPO" --env "$ENV_NAME"
printf '%s' "$ASP" | gh secret set NOTARY_PASSWORD --repo "$REPO" --env "$ENV_NAME"
echo "✓ Four secrets set in the '$ENV_NAME' environment of $REPO."
