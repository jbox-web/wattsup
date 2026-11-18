#!/bin/sh
# Builds the Rust core for the macOS app and generates its Swift bindings:
#   apple/Generated/Swift/WattsUpCore.swift        (SwiftPM target WattsUpCore)
#   apple/Generated/WattsUpCoreFFI.xcframework     (static library, one slice per installed Rust target)
set -eu
cd "$(dirname "$0")/.."
# MACOSX_DEPLOYMENT_TARGET is deliberately left unset. Exported (14.0), it also applies to
# the proc-macro dylibs cargo builds for the host, and dyld of macOS 27 then refuses to load
# them ("mis-aligned LINKEDIT string pool"). Nothing here compiles C, and rustc's own
# default for Apple targets (macOS 11) is below the app's minimum, so it is not needed.
profile=${PROFILE:-release}
target_dir=${CARGO_TARGET_DIR:-target}
out=apple/Generated
work="$target_dir/apple-bindings"
rm -rf "$out" "$work"
mkdir -p "$out/Swift" "$work/headers"

cargo build --profile "$profile" -p wattsup-ffi
cargo run -q --profile "$profile" -p wattsup-ffi --bin uniffi-bindgen -- generate \
  --library "$target_dir/$profile/libwattsup_ffi.dylib" --language swift --out-dir "$work"
mv "$work/WattsUpCore.swift" "$out/Swift/"
mv "$work/WattsUpCoreFFI.h" "$work/headers/"
mv "$work/WattsUpCoreFFI.modulemap" "$work/headers/module.modulemap"

libs=""
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  if rustup target list --installed 2>/dev/null | grep -qx "$target"; then
    cargo build --profile "$profile" -p wattsup-ffi --target "$target"
    libs="$libs $target_dir/$target/$profile/libwattsup_ffi.a"
  fi
done
if [ -n "$libs" ]; then
  # shellcheck disable=SC2086
  lipo -create $libs -output "$work/libwattsup_ffi.a"
else
  cp "$target_dir/$profile/libwattsup_ffi.a" "$work/"
fi
xcodebuild -create-xcframework -library "$work/libwattsup_ffi.a" -headers "$work/headers" \
  -output "$out/WattsUpCoreFFI.xcframework" >/dev/null
echo "bindings in $out"
