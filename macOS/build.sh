#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ "$#" -ne 1 ] || [[ "$1" != */Assistente\ IA.app && "$1" != 'Assistente IA.app' ]]; then
  printf 'Uso: /bin/bash macOS/build.sh "/caminho/Assistente IA.app"\n' >&2
  exit 2
fi
destination="$1"
if [ -e "$destination" ] || [ -L "$destination" ]; then
  printf 'O destino já existe: %s\n' "$destination" >&2
  exit 1
fi
version="${ASSISTENTE_VERSION:-$(/bin/bash "$root/ASSISTENTE-IA-MAC.command" --app version)}"
if [[ ! "$version" =~ ^[0-9]{1,4}\.[0-9]{1,4}(\.[0-9]{1,4})?$ ]]; then
  printf 'Versão inválida: %s\n' "$version" >&2
  exit 2
fi
parent="$(cd "$(dirname "$destination")" && pwd -P)"
scratch="$(mktemp -d "$parent/.assistente-build.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
bundle="$scratch/Assistente IA.app"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun swiftc -sdk "$sdk" -target "$arch-apple-macos13.0" -O -whole-module-optimization \
    "$root"/macOS/*.swift -o "$scratch/Assistente-$arch"
done
xcrun lipo -create "$scratch/Assistente-arm64" "$scratch/Assistente-x86_64" -output "$bundle/Contents/MacOS/Assistente"
cp -R "$root/lib" "$resources/"
cp -R "$root/macOS/en.lproj" "$root/macOS/es.lproj" "$root/macOS/pt-BR.lproj" "$resources/"
cp "$root/assets/Assistente.icns" "$resources/"
cp "$root/ASSISTENTE-IA-MAC.command" "$root/GUIA-DE-USO.md" "$root/LEIA-PRIMEIRO.txt" "$root/LICENSE" "$resources/"
cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>CFBundleDisplayName</key><string>Assistente IA</string>
  <key>CFBundleExecutable</key><string>Assistente</string>
  <key>CFBundleIdentifier</key><string>dev.anglerson.assistente-ia</string>
  <key>CFBundleIconFile</key><string>Assistente</string>
  <key>CFBundleName</key><string>Assistente IA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
if [ -z "${ASSISTENTE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign - "$bundle"
else
  codesign --force --sign "$ASSISTENTE_SIGN_IDENTITY" --options runtime --timestamp "$bundle"
fi
codesign --verify --deep --strict "$bundle"
# The staged bundle and the destination are on the same volume.
mv -n "$bundle" "$parent/Assistente IA.app"
[ ! -d "$bundle" ]
printf '%s/Assistente IA.app\n' "$parent"
