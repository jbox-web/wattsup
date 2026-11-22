#!/bin/sh
# Builds apple/dist/Watt's Up.app (the menu bar app, with the `wattsup` CLI and Sparkle
# inside) and its installer, apple/dist/WattsUp-<version>.pkg.
#
# Signing and notarization, all optional (without them: ad hoc app, unsigned package,
# nothing sent):
#   SIGN_ID="Developer ID Application: <team name>"
#       signs the app with that Keychain certificate, with the Hardened Runtime and a
#       secure timestamp that notarization requires. A stable identity also keeps the
#       notification permission, the login item and Keychain access across builds.
#   INSTALLER_ID="Developer ID Installer: <team name>"
#       signs the package; Apple notarizes no package without it.
#   NOTARY_PROFILE=<name>
#       sends the package to Apple's notary service (xcrun notarytool store-credentials
#       <name> ...), waits for the verdict and staples the ticket. Needs SIGN_ID and
#       INSTALLER_ID.
# or the same lines in apple/signing.env, which stays out of git.
# REPO=owner/name: the GitHub repository whose Releases Sparkle reads (default
# jbox-web/wattsup); apple/release.sh publishes there.
#
# Leaves apple/dist/Watt's Up.app, apple/dist/WattsUp-<version>.pkg, and for
# apple/release.sh the build number in apple/dist/build-number.
set -eu
cd "$(dirname "$0")/.."
# Local signing settings (not in git): the same variables, one per line.
# shellcheck disable=SC1091
if [ -f apple/signing.env ]; then . apple/signing.env; fi
SIGN_ID=${SIGN_ID:--}
INSTALLER_ID=${INSTALLER_ID:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
if [ -n "$NOTARY_PROFILE" ] && { [ "$SIGN_ID" = "-" ] || [ -z "$INSTALLER_ID" ]; }; then
  echo "NOTARY_PROFILE needs SIGN_ID and INSTALLER_ID: Apple notarizes only Developer ID signatures" >&2
  exit 1
fi

PRODUCT="Watt's Up"
EXECUTABLE=WattsUp
CLI=wattsup
BUNDLE_ID=fr.nicoladmin.wattsup
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
# Sparkle compares build numbers: a UTC date keeps them growing (yymmddHHMM fits
# CFBundleVersion's 32 bits).
BUILD=$(date -u +%y%m%d%H%M)
REPO=${REPO:-jbox-web/wattsup}
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

dist=apple/dist
app="$dist/$PRODUCT.app"
rm -rf "$dist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# Universal (Apple Silicon and Intel): the app claims macOS 14, which still runs on Intel
# Macs. Both Rust targets come with the rust tool of mise.toml.
echo "== Rust: bindings, $CLI"
apple/build-bindings.sh
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release -p wattsup-cli --target "$target"
done
lipo -create \
  "${CARGO_TARGET_DIR:-target}/aarch64-apple-darwin/release/$CLI" \
  "${CARGO_TARGET_DIR:-target}/x86_64-apple-darwin/release/$CLI" \
  -output "$app/Contents/MacOS/$CLI"

echo "== Swift: $PRODUCT"
swift build --package-path apple -c release --arch arm64 --arch x86_64 --product "$EXECUTABLE"
bin_path=$(swift build --package-path apple -c release --arch arm64 --arch x86_64 --show-bin-path)
# Installed under the product name, not "$EXECUTABLE": on a case-insensitive disk "WattsUp"
# and the CLI "wattsup" would be the same file.
cp "$bin_path/$EXECUTABLE" "$app/Contents/MacOS/$PRODUCT"
# Sparkle, without its XPC services: they serve sandboxed apps only.
mkdir -p "$app/Contents/Frameworks"
ditto "$bin_path/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
# Its MIT license asks for its notice in every copy: Settings › About links to it.
cp apple/.build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE.txt"

echo "== Icon"
swiftc -O -o "$dist/make-icon" apple/tools/MakeIcon/main.swift
"$dist/make-icon" "$dist/AppIcon.iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$dist/AppIcon.iconset"
rm -rf "$dist/make-icon" "$dist/AppIcon.iconset"

sed -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD|g" -e "s|@FEED_URL@|$FEED_URL|g" apple/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
cp -R apple/WattsUp/Resources/en.lproj apple/WattsUp/Resources/fr.lproj "$app/Contents/Resources/"

echo "== Signing"
xattr -cr "$app"
# Inside out: Sparkle's helpers, its framework, the CLI, then the bundle that seals them.
sign() {
  if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$@"
  else
    # Hardened Runtime and secure timestamp: both required by the notary service.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$@"
  fi
}
for part in Versions/B/Autoupdate Versions/B/Updater.app ""; do
  sign "$app/Contents/Frameworks/Sparkle.framework/$part"
done
sign --identifier "$BUNDLE_ID.cli" "$app/Contents/MacOS/$CLI"
sign --identifier "$BUNDLE_ID" "$app"
codesign --verify --strict --deep "$app"
# The strings of every language must be in the app itself: without them L10n falls back to
# SwiftPM's resource bundle, which the app does not have.
for language in en fr; do
  [ -f "$app/Contents/Resources/$language.lproj/Localizable.strings" ] || {
    echo "$language.lproj/Localizable.strings is missing from the app" >&2
    exit 1
  }
done
# Before anything is sent or published: the app must start.
apple/launch-check.sh "$app"
# A slice missing here would make the app refuse to start on that kind of Mac.
for binary in "$app/Contents/MacOS/$PRODUCT" "$app/Contents/MacOS/$CLI"; do
  for arch in arm64 x86_64; do
    lipo "$binary" -verify_arch "$arch" || { echo "$binary has no $arch slice" >&2; exit 1; }
  done
done

echo "== Package"
stage="$dist/stage"
mkdir -p "$stage/Applications"
ditto --norsrc --noextattr --noqtn "$app" "$stage/Applications/$PRODUCT.app"
pkg="$dist/WattsUp-$VERSION.pkg"
# The app must land in /Applications, never on top of a copy found elsewhere.
pkgbuild --analyze --root "$stage" "$dist/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$dist/component.plist"
COPYFILE_DISABLE=1 pkgbuild --root "$stage" --install-location / --scripts apple/pkg/scripts \
  --component-plist "$dist/component.plist" \
  --identifier "$BUNDLE_ID.pkg" --version "$VERSION" --ownership recommended "$dist/component.pkg" >/dev/null
sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@VERSION@|$VERSION|g" apple/pkg/distribution.xml > "$dist/distribution.xml"
if [ -n "$INSTALLER_ID" ]; then
  productbuild --distribution "$dist/distribution.xml" --package-path "$dist" --sign "$INSTALLER_ID" --timestamp "$pkg"
else
  productbuild --distribution "$dist/distribution.xml" --package-path "$dist" "$pkg"
fi
rm -rf "$stage" "$dist/component.pkg" "$dist/component.plist" "$dist/distribution.xml"
# The app as the package installs it must keep its seal. Extended attributes macOS will not
# let us remove (com.apple.provenance) travel in the payload as ._ entries and come back as
# attributes, which the seal does not cover: checked here rather than assumed.
rm -rf "$dist/check"
pkgutil --expand-full "$pkg" "$dist/check"
codesign --verify --strict --deep "$dist/check/component.pkg/Payload/Applications/$PRODUCT.app"
rm -rf "$dist/check"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "== Notarization"
  # Notarizing the package covers the app inside it.
  xcrun notarytool submit "$pkg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$pkg"
  xcrun stapler validate "$pkg"
  spctl --assess --type install "$pkg"
fi
# For apple/release.sh: the appcast names the build.
echo "$BUILD" > "$dist/build-number"
echo "built $app ($VERSION, build $BUILD), package $pkg"
