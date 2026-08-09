#!/bin/bash
# Faza 5 (plan): build + sign both targets. Run packaging/make_pkg.sh
# afterward to produce the installer.
set -euo pipefail
cd "$(dirname "$0")/.."

make clean
make driver
make daemon

./packaging/sign.sh build/AIHeadset.driver
./packaging/sign.sh build/AIHeadset.app

echo "Driver and app built and signed."
echo "Next: packaging/make_pkg.sh to build+sign the installer, then packaging/notarize.sh build/AIHeadset.pkg"
