#!/bin/bash
# Build a portable macOS application using the installed Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build work .build/local-module-cache

SPARKPEG_SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$SPARKPEG_SDK" ]; then SPARKPEG_SDK="$(xcrun --show-sdk-path)"; fi
read -r -a ARCHITECTURES <<< "${SPARKPEG_ARCHS:-$(uname -m)}"
SWIFT_FLAGS=(-O)
if [ "${1:-release}" = debug ]; then SWIFT_FLAGS=(-Onone -g); fi
BUILD_TEMP="$(mktemp -d "$PWD/work/sparkpeg-build.XXXXXX")"
trap 'rm -rf "$BUILD_TEMP"' EXIT
APP="$BUILD_TEMP/SparkPeg.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BINARIES=()
for arch in "${ARCHITECTURES[@]}"; do
  case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
  binary="$BUILD_TEMP/SparkPeg-$arch"
  xcrun swiftc -sdk "$SPARKPEG_SDK" -target "$arch-apple-macosx14.0" \
    -module-name Tendedero "${SWIFT_FLAGS[@]}" -module-cache-path "$PWD/.build/local-module-cache" \
    Sources/Tendedero/*.swift -o "$binary"
  BINARIES+=("$binary")
done
if [ "${#BINARIES[@]}" -eq 1 ]; then
  mv "${BINARIES[0]}" "$APP/Contents/MacOS/SparkPeg"
else
  xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/SparkPeg"
fi

# Original artwork is excluded from modified versions by the upstream license.
ICON="Sources/Tendedero/Resources/SparkPeg.png"
ICONSET="$BUILD_TEMP/SparkPeg.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/SparkPeg.icns"

LANGUAGES=""
for dir in Sources/Tendedero/Resources/*.lproj; do
  cp -R "$dir" "$APP/Contents/Resources/"
  LANGUAGES="$LANGUAGES<string>$(basename "$dir" .lproj)</string>"
done
cp LICENSE "$APP/Contents/Resources/LICENSE"

# Keep the existing local identifier so screenshots and preferences survive
# switching builds. Quit the original before running this local variant.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SparkPeg</string>
  <key>CFBundleDisplayName</key><string>SparkPeg</string>
  <key>CFBundleIdentifier</key><string>app.tendedero.Tendedero</string>
  <key>CFBundleExecutable</key><string>SparkPeg</string>
  <key>CFBundleIconFile</key><string>SparkPeg</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleVersion</key><string>32</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LANGUAGES}</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>SparkPeg watches your screenshot folder to display new images.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>SparkPeg watches the image folder you selected.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>SparkPeg watches the image folder you selected.</string>
  <key>NSScreenCaptureUsageDescription</key><string>SparkPeg recognizes text on screen when you press Command-Shift-E, so you can select it and create a note. Recognition happens on this Mac.</string>
  <key>NSServices</key><array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>Hang on SparkPeg</string></dict>
    <key>NSMessage</key><string>hangOnLine</string>
    <key>NSPortName</key><string>SparkPeg</string>
    <key>NSRequiredContext</key><dict/>
    <key>NSSendFileTypes</key><array><string>public.image</string></array>
  </dict><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>Pin</string></dict>
    <key>NSMessage</key><string>pinSelectedText</string>
    <key>NSPortName</key><string>SparkPeg</string>
    <key>NSServiceDescription</key><string>Hang selected text as a note</string>
    <key>NSRequiredContext</key><dict/>
    <key>NSSendTypes</key><array>
      <string>public.utf8-plain-text</string><string>NSStringPboardType</string><string>public.rtf</string>
    </array>
  </dict></array>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
if [ -d build/SparkPeg.app ]; then rm -rf build/SparkPeg.app; fi
mv "$APP" build/SparkPeg.app
echo "Built $PWD/build/SparkPeg.app"
