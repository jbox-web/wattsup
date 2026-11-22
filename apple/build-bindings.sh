#!/bin/sh
# Builds the Rust core for the macOS app and generates its Swift bindings:
#   apple/Generated/Swift/WattsUpCore.swift        (SwiftPM target WattsUpCore)
#   apple/Generated/WattsUpCoreFFI.xcframework     (static library, arm64 + x86_64)
set -eu
cd "$(dirname "$0")/.."
# MACOSX_DEPLOYMENT_TARGET is deliberately left unset. Exported (14.0), it also applies to
# the proc-macro dylibs cargo builds for the host, and dyld of macOS 27 then refuses to load
# them ("mis-aligned LINKEDIT string pool"). Nothing here compiles C, and rustc's own
# default for Apple targets (macOS 11) is below the app's minimum, so it is not needed.
profile=${PROFILE:-release}
# cargo writes the "dev" profile into target/debug, every other profile under its own name.
profile_dir=$profile
[ "$profile" = dev ] && profile_dir=debug
target_dir=${CARGO_TARGET_DIR:-target}
out=apple/Generated
work="$target_dir/apple-bindings"
rm -rf "$out" "$work"
mkdir -p "$out/Swift" "$work/headers"

cargo build --profile "$profile" -p wattsup-ffi
cargo run -q --profile "$profile" -p wattsup-ffi --bin uniffi-bindgen -- generate \
  --library "$target_dir/$profile_dir/libwattsup_ffi.dylib" --language swift --out-dir "$work"
mv "$work/WattsUpCore.swift" "$out/Swift/"
mv "$work/WattsUpCoreFFI.h" "$work/headers/"
mv "$work/WattsUpCoreFFI.modulemap" "$work/headers/module.modulemap"

# Both architectures, always: the app is universal, and a slice missing here only shows up
# later as "library not found" when Swift links the other one. Both Rust targets come with
# the rust tool of mise.toml; cargo says so plainly if one is missing. (Asking rustup which
# targets are installed is not reliable: it answers for its default toolchain, which may
# not be the one mise pins.)
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --profile "$profile" -p wattsup-ffi --target "$target"
done
lipo -create \
  "$target_dir/aarch64-apple-darwin/$profile_dir/libwattsup_ffi.a" \
  "$target_dir/x86_64-apple-darwin/$profile_dir/libwattsup_ffi.a" \
  -output "$work/libwattsup_ffi.a"
xcodebuild -create-xcframework -library "$work/libwattsup_ffi.a" -headers "$work/headers" \
  -output "$out/WattsUpCoreFFI.xcframework" >/dev/null
echo "bindings in $out"
