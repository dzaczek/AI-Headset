#!/bin/bash
# Buduje kompletną, podpisaną i notaryzowaną paczkę do instalacji na
# innym Macu. Jedna komenda, od zera do zipa.
#
# Notaryzacja jest obowiązkowa, nie ozdobna:
#   - sterownik: coreaudiod ładuje pluginy HAL przez piaskownicowy
#     proces XPC, który egzekwuje to przez AMFI -- bez notaryzacji
#     urządzenie się nie pojawi
#   - aplikacja: po skopiowaniu na inną maszynę dostaje atrybut
#     kwarantanny i wtedy Gatekeeper też jej wymaga
#
# To stopgap na brak certyfikatu "Developer ID Installer" -- gdy będzie,
# packaging/make_pkg.sh zbuduje normalny instalator .pkg.
set -euo pipefail
cd "$(dirname "$0")/.."

# Konfiguracja tożsamości -- poza repozytorium (patrz .env.example).
if [ -f packaging/.env ]; then
    set -a; . packaging/.env; set +a
fi

VERSION="$(cat VERSION)"
STAMP="$(date +%Y%m%d-%H%M)"
ZIP="build/AIHeadset-${VERSION}-${STAMP}.zip"
SIGN_IDENTITY="${AIHEADSET_SIGN_IDENTITY:?ustaw AIHEADSET_SIGN_IDENTITY w packaging/.env (patrz .env.example)}"
NOTARY_PROFILE="AC_NOTARY"

fail() { printf '\n\033[31mBŁĄD:\033[0m %s\n\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------
# Kontrola wstępna -- wszystko sprawdzamy ZANIM zacznie się budowanie,
# żeby nie tracić kilku minut na odkrycie braku poświadczeń na końcu.
# ---------------------------------------------------------------
step "Kontrola wstępna"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    fail "Brak certyfikatu podpisującego w Keychainie:
       $SIGN_IDENTITY
     Sprawdź: security find-identity -v -p codesigning"
fi
echo "  ✓ certyfikat Developer ID Application"

# Hasło aplikacji z packaging/.env działa też bez terminala; profil w
# Keychainie bywa niedostępny w kontekście nieinteraktywnym, bo
# `store-credentials` waliduje hasło, ale po cichu go wtedy nie zapisuje.
if [ -f packaging/.env ]; then
    set -a; . packaging/.env; set +a
fi

if [ -n "${SUPERSEC:-}" ]; then
    echo "  ✓ poświadczenia notaryzacji (packaging/.env)"
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "  ✓ poświadczenia notaryzacji ($NOTARY_PROFILE)"
else
    fail "Brak poświadczeń do notaryzacji. Wybierz jedno:

     a) utwórz packaging/.env z linią:
          SUPERSEC=<hasło aplikacji z appleid.apple.com>
        (plik jest w .gitignore, nie trafi do repo)

     b) albo w prawdziwym terminalu:
          xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
            --apple-id \"$AIHEADSET_APPLE_ID\" --team-id \"$AIHEADSET_TEAM_ID\""
fi

if ! ping -c1 -t3 api.apple.com >/dev/null 2>&1 && ! curl -s -m 5 -o /dev/null https://appleid.apple.com; then
    fail "Brak połączenia z serwerami Apple -- notaryzacja i znacznik czasu tego wymagają."
fi
echo "  ✓ łączność z Apple"
echo "  ✓ wersja do zbudowania: $VERSION ($STAMP)"

# ---------------------------------------------------------------
step "Budowanie"
make clean >/dev/null
make driver
make daemon

step "Podpisywanie (z bezpiecznym znacznikiem czasu -- wymagany do notaryzacji)"
./packaging/sign.sh build/AIHeadset.driver
./packaging/sign.sh build/AIHeadset.app

step "Notaryzacja sterownika (bez tego urządzenie się nie pojawi)"
./packaging/notarize.sh build/AIHeadset.driver

step "Notaryzacja aplikacji (bez tego Gatekeeper zablokuje ją po skopiowaniu)"
./packaging/notarize.sh build/AIHeadset.app

step "Składanie paczki"
# Całe składanie odbywa się POZA katalogiem projektu: build/ leży w
# Dokumentach synchronizowanych przez iCloud, a tamtejsze demony
# dostemplowują com.apple.FinderInfo na świeżo skopiowane bundle. Taki
# atrybut wpakowany do archiwum unieważnia podpis po rozpakowaniu i
# Gatekeeper na maszynie docelowej mówi "is damaged and can't be
# opened" -- co zdarzyło się naprawdę i nie wskazuje na przyczynę.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/dist"

ditto build/AIHeadset.driver "$STAGE/dist/AIHeadset.driver"
ditto build/AIHeadset.app "$STAGE/dist/AIHeadset.app"
cp packaging/install-manual.sh "$STAGE/dist/install.sh"
chmod +x "$STAGE/dist/install.sh"
echo "$VERSION ($STAMP)" > "$STAGE/dist/VERSION.txt"
xattr -cr "$STAGE/dist"

# Stare zipy to realna pułapka -- raz już doszło do rozpakowania
# nieaktualnego. Kasujemy poprzednie, a wersja jest w nazwie pliku.
rm -f build/AIHeadset-dist.zip build/AIHeadset-*.zip

# `zip -X`, nie `ditto -c -k`. Podpisane pliki noszą systemowy atrybut
# com.apple.provenance, którego `xattr -c` nie zdejmuje; ditto zapisuje
# go wtedy jako wpisy AppleDouble ("._CodeResources" itd.). ditto
# rozpakowuje je z powrotem poprawnie, ale `unzip` materializuje je
# jako PRAWDZIWE pliki wewnątrz bundla, co łamie pieczęć podpisu:
# "a sealed resource is missing or invalid". Paczka musi działać
# niezależnie od tego, czym odbiorca ją rozpakuje. -X pomija te
# metadane w ogóle; -y zachowałoby symlinki, ale bundle ich nie mają.
ZIP_ABS="$PWD/$ZIP"
( cd "$STAGE" && zip -q -r -X "$ZIP_ABS" dist )

step "Weryfikacja gotowej paczki"
# Sprawdzamy ROZPAKOWANE archiwum, nie źródło -- dokładnie to, co
# zobaczy druga maszyna. Weryfikacja samych bundli przed spakowaniem
# przepuściła wcześniej uszkodzony podpis.
#
# I to DWOMA narzędziami: `unzip` i `ditto` zachowują się inaczej wobec
# metadanych, a odbiorca użyje tego, co mu wygodne. Sprawdzenie tylko
# jednym przepuściło paczkę, która sypała się przy drugim.
VERIFY="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$VERIFY"' EXIT

if unzip -l "$ZIP" | grep -qE '/\._|__MACOSX'; then
    fail "Archiwum zawiera wpisy AppleDouble -- unzip zrobi z nich pliki w bundlu i złamie podpis."
fi
echo "  ✓ brak wpisów AppleDouble w archiwum"

for tool in unzip ditto; do
    rm -rf "$VERIFY/$tool"; mkdir -p "$VERIFY/$tool"
    case "$tool" in
        unzip) unzip -q "$ZIP" -d "$VERIFY/$tool" ;;
        ditto) ditto -x -k "$ZIP" "$VERIFY/$tool" ;;
    esac
    codesign --verify --deep --strict "$VERIFY/$tool/dist/AIHeadset.app" 2>/dev/null \
        || fail "podpis aplikacji nie waliduje się po rozpakowaniu przez $tool"
    codesign --verify --deep --strict "$VERIFY/$tool/dist/AIHeadset.driver" 2>/dev/null \
        || fail "podpis sterownika nie waliduje się po rozpakowaniu przez $tool"
    echo "  ✓ rozpakowanie przez $tool — podpisy OK"
done

for bundle in "$VERIFY/ditto/dist/AIHeadset.app" "$VERIFY/ditto/dist/AIHeadset.driver"; do
    name="$(basename "$bundle")"
    # Twarde bramki: obie są deterministyczne i offline'owe, a razem
    # dokładnie odpowiadają temu, czego wymaga maszyna docelowa.
    codesign --verify --deep --strict "$bundle" 2>/dev/null \
        || fail "$name: podpis nie waliduje się po rozpakowaniu -- tak właśnie powstaje komunikat \"is damaged\""
    xcrun stapler validate "$bundle" >/dev/null 2>&1 \
        || fail "$name: brak wbitego biletu notaryzacji"

    # spctl bywa chwiejny (potrafi zwrócić "Insufficient Context", gdy
    # ocena wymaga rundy sieciowej), więc jest tylko informacyjny --
    # wbity bilet i tak przesądza o zachowaniu offline.
    if spctl -a -t install "$bundle" >/dev/null 2>&1; then
        gatekeeper="Gatekeeper: accepted"
    else
        gatekeeper="Gatekeeper: bez rozstrzygnięcia (bilet wbity, więc offline zadziała)"
    fi

    echo "  ✓ $name — podpis i notaryzacja OK po rozpakowaniu"
    echo "      architektury: $(lipo -archs "$bundle/Contents/MacOS/AIHeadset" 2>/dev/null)"
    echo "      $gatekeeper"
done

printf '\n\033[32mGotowe:\033[0m %s\n' "$ZIP"
printf 'Wersja: %s (%s)\n\n' "$VERSION" "$STAMP"
echo "Na drugim Macu:"
echo "  1. rozpakuj archiwum"
echo "  2. cd dist && ./install.sh"
echo "  3. w aplikacji: Ustawienia -> wpisz API Key (nie wędruje z paczką)"
