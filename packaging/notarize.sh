#!/bin/bash
# Notarizes an already-signed bundle and staples the ticket (plan
# section 5.3). notarytool needs a zip/pkg/dmg to submit; the staple
# step attaches the resulting ticket to the bundle so it validates
# offline on the target machine.
#
# Credentials, in order of preference:
#   1. packaging/.env with SUPERSEC (app-specific password) -- works in
#      non-interactive contexts, which the Keychain profile does not:
#      `notarytool store-credentials` validates the password but
#      silently fails to persist it when run without a TTY, which is
#      why the AC_NOTARY profile kept "vanishing" during development.
#   2. the AC_NOTARY Keychain profile, if it happens to be there.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE="${1:?usage: notarize.sh <path-to-signed-bundle>}"
PROFILE="AC_NOTARY"

# Wczytanie MUSI być przed użyciem zmiennych -- inaczej `:?` wywali się
# na pustej wartości, mimo że plik ją zawiera.
if [ -f packaging/.env ]; then
    set -a; . packaging/.env; set +a
fi

APPLE_ID="${AIHEADSET_APPLE_ID:?ustaw AIHEADSET_APPLE_ID w packaging/.env}"
TEAM_ID="${AIHEADSET_TEAM_ID:?ustaw AIHEADSET_TEAM_ID w packaging/.env}"

if [ -n "${SUPERSEC:-}" ]; then
    AUTH=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$SUPERSEC")
elif xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    AUTH=(--keychain-profile "$PROFILE")
else
    echo "BŁĄD: brak poświadczeń do notaryzacji." >&2
    echo "  Ustaw SUPERSEC=<hasło aplikacji> w packaging/.env," >&2
    echo "  albo utwórz profil: xcrun notarytool store-credentials \"$PROFILE\" \\" >&2
    echo "    --apple-id \"$APPLE_ID\" --team-id \"$TEAM_ID\"   (w prawdziwym terminalu)" >&2
    exit 1
fi

ZIP="$(mktemp -t aiheadset-notarize).zip"
trap 'rm -f "$ZIP"' EXIT

ditto -c -k --keepParent "$BUNDLE" "$ZIP"
xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait
xcrun stapler staple "$BUNDLE"

echo "Notarized and stapled: $BUNDLE"
