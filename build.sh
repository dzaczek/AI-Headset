#!/bin/bash
# Szybki build samej aplikacji -> build/AIHeadset.app (bez sterownika,
# bez podpisu). Pełny build do dystrybucji: packaging/build.sh.
set -euo pipefail
cd "$(dirname "$0")"

make daemon
echo "Gotowe: build/AIHeadset.app (uruchom: ./run.sh)"
