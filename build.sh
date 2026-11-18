#!/bin/zsh
# Builds Folio.app into ./build. Usage: ./build.sh [--install] [--run]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Folio"
APP="build/Folio.app"

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
echo "Built $APP"

for arg in "$@"; do
  case $arg in
    --install) rm -rf /Applications/Folio.app && cp -R "$APP" /Applications/ && echo "Installed to /Applications" ;;
    --run) open "$APP" ;;
  esac
done
