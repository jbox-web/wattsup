#!/bin/sh
# Builds apple/dist/Watt's Up.app: the menu bar app, with the `wattsup` CLI inside.
#
# Signing and notarization, both optional (without them: ad hoc signature, nothing sent):
#   SIGN_ID="Developer ID Application: <team name>"
#       signs with that Keychain certificate, with the Hardened Runtime and a secure
#       timestamp that notarization requires. A stable identity also keeps the
#       notification permission, the login item and Keychain access across builds.
#   NOTARY_PROFILE=<name>
#       sends the app to Apple's notary service (xcrun notarytool store-credentials
#       <name> ...), waits for the verdict and staples the ticket. Needs SIGN_ID.
# or the same lines in apple/signing.env, which stays out of git.
#
# Leaves apple/dist/Watt's Up.app and apple/dist/WattsUp-<version>.zip, the archive to
# publish.
set -eu
cd "$(dirname "$0")/.."
# Local signing settings (not in git): the same variables, one per line.
# shellcheck disable=SC1091
if [ -f apple/signing.env ]; then . apple/signing.env; fi
SIGN_ID=${SIGN_ID:--}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_ID" = "-" ]; then
  echo "NOTARY_PROFILE needs SIGN_ID: Apple notarizes only Developer ID signatures" >&2
  exit 1
fi

PRODUCT="Watt's Up"
EXECUTABLE=WattsUp
CLI=wattsup
BUNDLE_ID=fr.nicoladmin.wattsup
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
BUILD=$(date -u +%y%m%d%H%M)

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

echo "== Icon"
swiftc -O -o "$dist/make-icon" apple/tools/MakeIcon/main.swift
"$dist/make-icon" "$dist/AppIcon.iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$dist/AppIcon.iconset"
rm -rf "$dist/make-icon" "$dist/AppIcon.iconset"

sed -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD|g" apple/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
cp -R apple/WattsUp/Resources/en.lproj apple/WattsUp/Resources/fr.lproj "$app/Contents/Resources/"

echo "== Signing"
xattr -cr "$app"
# The CLI first, then the bundle that seals it.
sign() {
  if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - --identifier "$1" "$2"
  else
    # Hardened Runtime and secure timestamp: both required by the notary service.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" --identifier "$1" "$2"
  fi
}
sign "$BUNDLE_ID.cli" "$app/Contents/MacOS/$CLI"
sign "$BUNDLE_ID" "$app"
codesign --verify --strict "$app"
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

archive="$dist/WattsUp-$VERSION.zip"
if [ -n "$NOTARY_PROFILE" ]; then
  echo "== Notarization"
  ditto -c -k --keepParent "$app" "$archive"
  xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute "$app"
fi
# The archive to publish, made again so that it holds the stapled ticket.
rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
echo "built $app ($VERSION, build $BUILD), archive $archive"
