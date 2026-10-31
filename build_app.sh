#!/bin/zsh
set -euo pipefail

help_version="$(/usr/bin/plutil -extract reviewedVersion raw -o - App/Help/guide.json)"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
if [[ "$help_version" != "$app_version" ]]; then
    echo "Review App/Help/guide.json and set reviewedVersion to $app_version before packaging." >&2
    exit 1
fi

if [[ "${1:-}" != "--skip-build" ]]; then
    swift build -c release
fi
# --skip-build packages the release executable just produced by swift test -c release.
[[ -x .build/release/MyWizard ]]
if ! /bin/zsh build_icon.sh; then
    [[ -f App/MyWizard.icns ]] || exit 1
    echo "Icon generation unavailable; using the existing MyWizard.icns" >&2
fi
staging_dir="$(mktemp -d .build/package.XXXXXX)"
bundle_path="$staging_dir/MyWizard.app"
mkdir -p "$bundle_path/Contents/MacOS"
mkdir -p "$bundle_path/Contents/Resources"
cp App/Info.plist "$bundle_path/Contents/Info.plist"
build_timestamp="$(date +%s)"
build_day="$(TZ=Europe/Paris date -r "$build_timestamp" +%-d)"
case "$build_day" in
    1|21|31) build_suffix="st" ;;
    2|22) build_suffix="nd" ;;
    3|23) build_suffix="rd" ;;
    *) build_suffix="th" ;;
esac
build_month_year="$(TZ=Europe/Paris LC_ALL=en_US.UTF-8 date -r "$build_timestamp" '+%B %Y')"
/usr/bin/plutil -insert MyWizardBuildDate -string "$build_day$build_suffix $build_month_year" "$bundle_path/Contents/Info.plist"
cp App/MyWizard.icns "$bundle_path/Contents/Resources/MyWizard.icns"
cp -R App/Help "$bundle_path/Contents/Resources/Help"
cp .build/release/MyWizard "$bundle_path/Contents/MacOS/MyWizard"
cp -R .build/release/FluidAudio_FluidAudio.bundle "$bundle_path/Contents/Resources/"
mkdir -p "$bundle_path/Contents/Resources/Licenses"
cp .build/checkouts/FluidAudio/LICENSE "$bundle_path/Contents/Resources/Licenses/FluidAudio-LICENSE.txt"
cp -R .build/checkouts/FluidAudio/ThirdPartyLicenses/ "$bundle_path/Contents/Resources/Licenses/"
signing_identity="${MYWIZARD_SIGNING_IDENTITY:-Apple Development: yvan.cognasse@gmail.com (NX4DNX7JY2)}"
codesign --force --sign "$signing_identity" "$bundle_path"
codesign --verify --deep --strict "$bundle_path"
# Keep the last valid application intact while Keychain authorization is pending.
if [[ -d .build/MyWizard.app ]]; then
    mv .build/MyWizard.app "$staging_dir/Previous-MyWizard.app"
fi
mv "$bundle_path" .build/MyWizard.app
echo "Application built: .build/MyWizard.app (previous signed bundle retained in $staging_dir)"
