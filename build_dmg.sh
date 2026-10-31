#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

if [[ "${1:-}" != "--skip-build" ]]; then
    ./build_app.sh
fi

app_path=".build/MyWizard.app"
codesign --verify --deep --strict "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")"
architecture="$(lipo -archs "$app_path/Contents/MacOS/MyWizard")"
mkdir -p dist
staging_dir="$(mktemp -d .build/dmg.XXXXXX)"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir/contents"
ditto "$app_path" "$staging_dir/contents/MyWizard.app"
ln -s /Applications "$staging_dir/contents/Applications"
cat > "$staging_dir/contents/Installation.txt" <<EOF
MyWizard $version (bundle $bundle)

Configuration requise : macOS $minimum_macos ou ultérieur.
Architecture : $architecture (arm64 = Apple Silicon).

Installation : glissez MyWizard.app dans le dossier Applications,
puis ouvrez MyWizard depuis Applications.

Cette version utilise une signature Apple Development et n'est pas notarifiée.
macOS peut bloquer son ouverture sur un autre Mac. Si vous connaissez et
faites confiance à sa provenance, utilisez l'option d'ouverture proposée dans
Réglages Système > Confidentialité et sécurité après la première tentative.
Les règles de sécurité d'un Mac géré peuvent empêcher cette autorisation.

Au premier démarrage, macOS peut demander les autorisations de microphone,
de reconnaissance vocale et de capture audio. Les modèles nécessaires
peuvent être téléchargés lors de la première utilisation.
La capture commence lorsque vous cliquez sur Start.
EOF

filename="MyWizard-${version}-build-${bundle}-${architecture// /-}.dmg"
hdiutil create -volname "MyWizard $version" -srcfolder "$staging_dir/contents" \
    -format UDZO -ov "$staging_dir/$filename"
hdiutil verify "$staging_dir/$filename"
mv "$staging_dir/$filename" "dist/$filename"
(cd dist && shasum -a 256 "$filename" > "$filename.sha256")
echo "DMG created: $PWD/dist/$filename"
