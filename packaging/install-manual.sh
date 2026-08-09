#!/bin/bash
# Instalator ręczny AI Headset (uruchamiany na maszynie docelowej).
# Kopiuje sterownik HAL i aplikację, restartuje coreaudiod.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d "AIHeadset.driver" ] || [ ! -d "AIHeadset.app" ]; then
  echo "Brak AIHeadset.driver lub AIHeadset.app obok tego skryptu." >&2
  exit 1
fi

NEW_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AIHeadset.app/Contents/Info.plist 2>/dev/null || echo '?')"
NEW_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' AIHeadset.app/Contents/Info.plist 2>/dev/null || echo '?')"
echo "Instaluję AI Headset $NEW_VERSION ($NEW_BUILD)"

if [ -d "/Applications/AIHeadset.app" ]; then
  OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/AIHeadset.app/Contents/Info.plist 2>/dev/null || echo '?')"
  OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/AIHeadset.app/Contents/Info.plist 2>/dev/null || echo '?')"
  echo "Zastępuję już zainstalowaną wersję $OLD_VERSION ($OLD_BUILD)"
fi

echo "Instalacja wymaga uprawnień administratora."
echo "Na chwilę ucichnie dźwięk w całym systemie (restart coreaudiod) -- to normalne."
echo

sudo rm -rf "/Library/Audio/Plug-Ins/HAL/AIHeadset.driver"
sudo cp -R AIHeadset.driver /Library/Audio/Plug-Ins/HAL/

rm -rf "/Applications/AIHeadset.app"
cp -R AIHeadset.app /Applications/

# `launchctl kickstart -k system/com.apple.audio.coreaudiod` bywa
# blokowane przez SIP (błąd 150); killall działa zawsze -- coreaudiod
# jest nadzorowany przez launchd i wstaje sam.
sudo killall coreaudiod 2>/dev/null || true

echo
echo "Gotowe."
echo "  - urządzenie 'AI Headset' powinno być widoczne w Ustawieniach Dźwięku"
echo "  - aplikacja: /Applications/AIHeadset.app (ikona w pasku menu)"
echo
echo "Przy pierwszym uruchomieniu macOS zapyta o dostęp do mikrofonu."
echo "Dla skrótu klawiszowego (Cmd+Shift+A) trzeba dodatkowo nadać"
echo "uprawnienie Accessibility w Ustawieniach systemowych -> Prywatność."
open /Applications/AIHeadset.app
