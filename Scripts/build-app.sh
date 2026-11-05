#!/bin/zsh
# Собирает build/Singluse.app. Подпись сертификатом разработчика нужна, чтобы macOS
# не сбрасывала выданные разрешения после каждой пересборки.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP="$ROOT/build/Singluse.app"
CONTENTS="$APP/Contents"

swift build -c release --product Singluse
BIN="$(swift build -c release --show-bin-path)/Singluse"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Singluse"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Singluse</string>
    <key>CFBundleIdentifier</key><string>com.askatbek.singluse</string>
    <key>CFBundleName</key><string>Singluse</string>
    <key>CFBundleDisplayName</key><string>Singluse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>ru</string>
    <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string><string>es</string><string>zh-Hans</string><string>ar</string><string>fr</string><string>vi</string><string>ko</string><string>tl</string></array>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Singluse слушает микрофон, только пока вы держите клавишу голосового ввода.</string>
    <key>NSAppleEventsUsageDescription</key><string>Singluse создаёт заметки встреч в приложении «Заметки».</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Singluse превращает сказанное в текст и вставляет его у курсора.</string>
</dict>
</plist>
PLIST

python3 "$ROOT/Scripts/make-strings.py" "$ROOT/Localization" "$CONTENTS/Resources"

# Мост к системному «Сейчас играет»: загружается системным perl, см. Helpers/nowplaying/bridge.m.
clang -fobjc-arc -dynamiclib -arch arm64 -arch arm64e -framework Foundation "$ROOT/Helpers/nowplaying/bridge.m" -o "$CONTENTS/Resources/nowplaying.dylib"
cp "$ROOT/Helpers/nowplaying/bridge.pl" "$CONTENTS/Resources/nowplaying.pl"

ICON_PNG="$ROOT/build/icon-1024.png"
ICONSET="$ROOT/build/AppIcon.iconset"
if [[ ! -f "$ROOT/build/AppIcon.icns" || "$ROOT/Scripts/make-icon.swift" -nt "$ROOT/build/AppIcon.icns" ]]; then
    swift "$ROOT/Scripts/make-icon.swift" "$ICON_PNG"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then codesign --force --sign "$IDENTITY" "$CONTENTS/Resources/nowplaying.dylib" 2>/dev/null || true; fi
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Подписано: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Подписано локально (ad-hoc): разрешения придётся выдавать заново после пересборки"
fi
codesign --verify --strict "$APP"
echo "Готово: $APP"
