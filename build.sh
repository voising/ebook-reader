#!/bin/zsh
# Builds Folio.app (Mac) into ./build. Usage: ./build.sh [--adhoc] [--install] [--run]
#
# Default: the signed build from Folio.xcodeproj. It has the iCloud entitlement, so it shares its
#          data and books with the iPad app through the iCloud.com.voz.folio container.
# --adhoc: a quick unsigned build from Package.swift. No iCloud container: it keeps its data in the
#          "Folio" folder of iCloud Drive and does not sync with the iPad.
#
# The iPad app is built from Xcode: open Folio.xcodeproj, pick the Folio-iOS scheme and your iPad.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Folio.app"
mkdir -p build

if [[ " $* " == *" --adhoc "* ]]; then
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/Folio"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/Folio"
  cp Support/Info.plist "$APP/Contents/Info.plist"
  if [[ ! -f build/AppIcon.icns ]]; then
    if [[ -f Support/icon-codex/folio-icon-1024.png ]]; then
      swift Support/clean-icon.swift Support/icon-codex/folio-icon-1024.png build/AppIcon.iconset
    else
      swift Support/make-icon.swift build/AppIcon.iconset
    fi
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  fi
  cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  codesign --force --sign - "$APP"
else
  xcodebuild -project Folio.xcodeproj -scheme Folio-macOS -configuration Release \
    -derivedDataPath .build/xcode -allowProvisioningUpdates -quiet build
  rm -rf "$APP"
  ditto .build/xcode/Build/Products/Release/Folio.app "$APP"
fi
echo "Built $APP"

for arg in "$@"; do
  case $arg in
    --install) rm -rf /Applications/Folio.app && cp -R "$APP" /Applications/ && echo "Installed to /Applications" ;;
    --run) open "$APP" ;;
  esac
done
