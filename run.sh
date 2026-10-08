#!/bin/bash
# Build + lokalny podpis + uruchomienie aplikacji.
#
#   ./run.sh            uruchamia z build/ (najszybciej)
#   ./run.sh install    instaluje do /Applications i uruchamia stamtąd
#                       (do prawdziwych rozmów -- uprawnienia zostają)
#
# Dopisz "logs" (np. ./run.sh logs, ./run.sh install logs), żeby po
# starcie śledzić log aplikacji; Ctrl+C kończy podgląd, nie aplikację.
set -euo pipefail
cd "$(dirname "$0")"

target=run
logs=false
for arg in "$@"; do
    case "$arg" in
        install) target=install-app ;;
        logs)    logs=true ;;
        *) echo "nieznana opcja: $arg (dozwolone: install, logs)" >&2; exit 1 ;;
    esac
done

# Podpis lokalny bierze tożsamość z packaging/.env -- bez niej make
# przerwałby się dopiero w połowie, z mniej czytelnym komunikatem.
if [ ! -f packaging/.env ]; then
    echo "Brak packaging/.env (tożsamość do podpisu). Utwórz go:" >&2
    echo "  cp packaging/.env.example packaging/.env" >&2
    echo "  i wpisz AIHEADSET_TEAM_ID oraz AIHEADSET_SIGN_IDENTITY" >&2
    echo "  (lista certyfikatów: security find-identity -v -p codesigning)" >&2
    exit 1
fi

make "$target"

if $logs; then
    make logs
fi
