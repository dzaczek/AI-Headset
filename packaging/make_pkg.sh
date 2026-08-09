#!/bin/bash
# Faza 5.1-5.2 (plan): stages the signed driver + app into one
# component package, then wraps it via distribution.xml into the
# final signed .pkg. Requires a "Developer ID Installer" certificate
# (separate from "Developer ID Application" -- a Mac App Store "3rd
# Party Mac Developer Installer" cert does NOT work here). Run
# packaging/build.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f packaging/.env ]; then
    set -a; . packaging/.env; set +a
fi
INSTALLER_IDENTITY="${AIHEADSET_INSTALLER_IDENTITY:?ustaw AIHEADSET_INSTALLER_IDENTITY w packaging/.env}"
VERSION="0.1.0"
BUILD_DIR="build"
STAGING="$BUILD_DIR/pkg-root"

for bundle in "$BUILD_DIR/AIHeadset.driver" "$BUILD_DIR/AIHeadset.app"; do
  if [ ! -d "$bundle" ]; then
    echo "Missing $bundle -- run packaging/build.sh first." >&2
    exit 1
  fi
done

rm -rf "$STAGING"
mkdir -p "$STAGING/Applications"
mkdir -p "$STAGING/Library/Audio/Plug-Ins/HAL"
mkdir -p "$STAGING/Library/LaunchAgents"

cp -R "$BUILD_DIR/AIHeadset.app" "$STAGING/Applications/"
cp -R "$BUILD_DIR/AIHeadset.driver" "$STAGING/Library/Audio/Plug-Ins/HAL/"
cp "daemon/AIHeadset/Resources/cat.sysop.aiheadset.plist" "$STAGING/Library/LaunchAgents/"

pkgbuild --root "$STAGING" \
  --identifier cat.sysop.aiheadset.pkg \
  --version "$VERSION" \
  --scripts packaging/scripts \
  --install-location / \
  "$BUILD_DIR/AIHeadsetComponent.pkg"

productbuild --distribution packaging/distribution.xml \
  --package-path "$BUILD_DIR" \
  --sign "$INSTALLER_IDENTITY" \
  "$BUILD_DIR/AIHeadset.pkg"

echo "Built $BUILD_DIR/AIHeadset.pkg -- notarize next: ./packaging/notarize.sh build/AIHeadset.pkg"
