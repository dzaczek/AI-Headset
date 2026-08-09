#!/bin/bash
# Signs a built .driver (or .app) bundle with the Developer ID Application
# identity, hardened runtime + secure timestamp (plan section 5.2).
#
# Pass --local as the second argument for fast dev iteration: skips the
# secure timestamp, which requires reaching Apple's timestamp server
# and fails outright when that server is unreachable ("The timestamp
# service is not available"). A timestamp is mandatory for
# notarization, so NEVER use --local for anything you intend to
# notarize or distribute -- only for local run/test cycles.
set -euo pipefail

cd "$(dirname "$0")/.."

# Tożsamość podpisująca pochodzi z packaging/.env (plik jest w
# .gitignore), żeby publiczne repozytorium nie zawierało adresu e-mail
# ani nazwiska. Wzór: packaging/.env.example
if [ -f packaging/.env ]; then
    set -a; . packaging/.env; set +a
fi

: "${AIHEADSET_TEAM_ID:?ustaw AIHEADSET_TEAM_ID w packaging/.env (patrz .env.example)}"
: "${AIHEADSET_SIGN_IDENTITY:?ustaw AIHEADSET_SIGN_IDENTITY w packaging/.env}"

IDENTITY="$AIHEADSET_SIGN_IDENTITY"
BUNDLE="${1:?usage: sign.sh <path-to-bundle> [--local]}"
MODE="${2:-}"

if [ "$MODE" = "--local" ]; then
  TIMESTAMP_FLAG="--timestamp=none"
else
  TIMESTAMP_FLAG="--timestamp"
fi

# This project lives under an iCloud-synced Documents folder. The
# fileprovider/Finder-sync daemons re-stamp com.apple.FinderInfo and
# com.apple.fileprovider.fpfs# xattrs on freshly-created bundles faster
# than `xattr -cr` can strip them, and codesign refuses to sign a
# bundle carrying those ("resource fork, Finder information, or
# similar detritus not allowed"). Signing a copy in a scratch
# directory outside iCloud sync sidesteps it reliably.
SCRATCH="$(mktemp -d)"
BASENAME="$(basename "$BUNDLE")"
trap 'rm -rf "$SCRATCH"' EXIT

cp -R "$BUNDLE" "$SCRATCH/$BASENAME"
xattr -cr "$SCRATCH/$BASENAME"

# Aplikacja potrzebuje uprawnienia do mikrofonu. Przy hardened
# runtime macOS bez niego nie pokaże nawet pytania o dostęp -- tccd
# odmawia z "Policy disallows prompt", a aplikacja nie trafia na listę
# w Ustawieniach. Sterownik go nie potrzebuje, więc dodajemy tylko
# tam, gdzie jest sens.
ENTITLEMENTS_ARGS=()
if [[ "$BASENAME" == *.app ]]; then
    ENTITLEMENTS="daemon/AIHeadset/AIHeadset.entitlements"
    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "BŁĄD: brak $ENTITLEMENTS -- bez niego mikrofon nie zadziała." >&2
        exit 1
    fi
    ENTITLEMENTS_ARGS=(--entitlements "$ENTITLEMENTS")
fi

# Uwaga na bash 3.2 (wciąż domyślny na macOS): "${ARR[@]}" na pustej
# tablicy przy `set -u` przerywa skrypt. Stąd forma z ${ARR+...}.
codesign --force --options runtime "$TIMESTAMP_FLAG" \
  ${ENTITLEMENTS_ARGS[@]+"${ENTITLEMENTS_ARGS[@]}"} \
  --sign "$IDENTITY" \
  "$SCRATCH/$BASENAME"

codesign --verify --deep --strict --verbose=2 "$SCRATCH/$BASENAME"

# Sprawdzenie wprost: adhoc albo brak Team ID oznacza, że podpisanie
# po cichu nie doszło do skutku. Notaryzacja odrzuciłaby to dopiero po
# kilku minutach, a przy uprawnieniach TCC objaw byłby jeszcze bardziej
# mylący -- lepiej przerwać tutaj.
# Uwaga: `codesign ... | grep -q` przy `set -o pipefail` daje fałszywy
# błąd -- grep kończy się wcześnie, codesign dostaje SIGPIPE i potok
# zwraca niezero. Dlatego najpierw zbieramy wyjście, dopiero potem je
# przeszukujemy.
SIGN_INFO="$(codesign -dv "$SCRATCH/$BASENAME" 2>&1 || true)"
if ! printf '%s' "$SIGN_INFO" | grep -q "TeamIdentifier=$AIHEADSET_TEAM_ID"; then
    echo "BŁĄD: $BASENAME nie ma prawidłowego podpisu Developer ID po podpisaniu." >&2
    exit 1
fi

rm -rf "$BUNDLE"
cp -R "$SCRATCH/$BASENAME" "$BUNDLE"

echo "Signed OK: $BUNDLE"
