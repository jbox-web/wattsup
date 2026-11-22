# Watt's Up

A macOS menu bar app, its window and a CLI that watch UPSes served by NUT servers
(`upsd`): state, charge, runtime, notifications, and a line per UPS in Apple's Batteries
widget. Rust core, Swift app, joined by UniFFI.

Out of scope by design: shutting machines down, anything cloud, iPhone and iPad apps, a
widget of our own, history and graphs, a headless daemon, TLS (`STARTTLS`), and UPSes
plugged into the Mac by USB (macOS already shows those).

## Layout

| Path | Role |
|---|---|
| `crates/wattsup-core` | NUT client (`client.rs`, `protocol.rs`), model and states (`model.rs`), events (`changes.rs`), configuration (`config.rs`), Batteries widget (`power_source.rs`) |
| `crates/wattsup-ffi` | What Swift sees of the core, through UniFFI proc macros |
| `crates/cli` | The `wattsup` binary |
| `crates/test-support` | A fake `upsd` for tests, also runnable (`--bin fake-upsd`) |
| `apple/WattsUp` | The app: `Model.swift` (poll loops, editing the configuration), `StatusMenu.swift`, `MainWindow.swift`, `SettingsView.swift`, `Notifier.swift`, `Keychain.swift`, `L10n.swift`, `Updates.swift` (Sparkle) |
| `apple/pkg` | The installer: `distribution.xml` and its `preinstall`/`postinstall` scripts |
| `apple/Tests` | XCTest suite of the app |
| `apple/Generated` | Generated bindings; never edited, never committed |

## Commands

Everything goes through mise; CI runs the same tasks.

```sh
mise run dev:test        # Rust tests
mise run dev:lint        # clippy, warnings are errors
mise run dev:fmt-check
mise run dev:bindings    # Rust library + Swift bindings; needed before any swift command
mise run dev:swift-test  # app tests
mise run dev:package     # apple/dist/Watt's Up.app and WattsUp-<version>.pkg; signed and notarized per apple/signing.env
mise run dev:install     # copies it to /Applications
mise run dev:release     # tag, GitHub Release with the .pkg and appcast.xml (apple/release.sh; NOTES=file for notes)
```

Run `dev:bindings` again after any change to the public surface of `wattsup-ffi`: until
then Swift does not see it.

To watch the app react without a real power cut, run the fake server and point an entry
of a trial configuration at it (`WATTSUP_CONFIG=/path/to/file` makes the app read another
file than `~/.config/wattsup/config.toml`, and keep its passwords under
`jbox.wattsup-trial.<name>`):

```sh
cargo run -p test-support --bin fake-upsd -- 34930 "OL:40" "OB DISCHRG:60" "OL:600"
```

## Rules of this code

- **Read-only.** The client never sends `SET` or `INSTCMD`, and nothing here shuts a
  machine down. Both are out of scope by design.
- **Tests first.** Expected values come from the NUT protocol documentation and the spec,
  never from what the code prints. The client is tested against the fake `upsd`, never
  against a real server.
- **A missing variable is an absent field** (`None`, `nil`), never a zero.
- **No secret** in the configuration file, a log, or an error message. NUT passwords live
  in the macOS Keychain (service `jbox.wattsup.<name>`, account = the NUT username).
  `Credentials` has no `Debug` on purpose.
- **One site never delays another.** Each UPS has its own poll loop; its blocking calls
  (the poll, and the Keychain read it needs, cached until the next reload) run on a GCD
  thread, never on the main thread nor Swift's cooperative pool. Editing an entry in the
  settings still touches the Keychain on the main thread. A request has an overall
  deadline (three timeouts, checked at every socket read) and a 64 KiB line limit, and
  name resolution is bounded too. A result that arrives after a stop, a reload or a
  newer poll is dropped (`awaited` in `Model.swift`).
- **The app never overwrites a configuration it could not read.** Every edit re-reads the
  file from disk and applies the change to that (`Model.edit`).
- **Strings are keyed by their English text.** SwiftUI views localize by themselves; code
  uses `tr()`. `en.lproj` and `fr.lproj` must hold the same keys (a test checks). Tests
  pin the language with `L10n.forced`.

## The Batteries widget: what not to change lightly

`power_source.rs` publishes each UPS through private IOKit functions
(`IOPSCreatePowerSource`, `IOPSSetPowerSourceDetails`, `IOPSReleasePowerSource`).

- It publishes `Type = Accessory Source`, **never `UPS`**. A source of type `UPS` that
  reports `Battery Power` makes macOS believe the Mac itself runs on that UPS and switch
  to its battery energy settings (measured on macOS 27.2). An accessory source leaves the
  Mac untouched.
- `Accessory Category = Battery Case` is what gives the line its plug icon: the widget
  only draws an icon for categories it knows, and there is none for a UPS.
- A source lives as long as the process that created it, which is why the CLI does not
  publish.
- Any failure of these calls turns publishing off for the session and must never affect
  the window, the menu, the CLI or notifications.

## Traps already met

- **Xcode 27 to assemble the app.** With Xcode 26 the universal release build of
  `apple/package.sh` fails to link (`library not found for -lwattsup_ffi`), while
  `swift test` passes; the `app` job of CI runs on GitHub's `xcode-27` image for that reason.
- **`Bundle.module` does not exist in the assembled app.** SwiftPM's resource bundle is
  there for tests and `swift run` only; touching `Bundle.module` in the app is a fatal
  error at launch (it shipped in 0.1.1). `L10n` looks in the app bundle first and reaches
  for it only as a fallback. `apple/launch-check.sh`, run by `package.sh` after signing and
  before the package and its notarization, starts the assembled app and fails on a crash.
- **Case-insensitive disk.** Inside the bundle the app executable is named `Watt's Up`,
  not `WattsUp`: `WattsUp` and the CLI `wattsup` would be the same file.
- **`MACOSX_DEPLOYMENT_TARGET` is not exported in `apple/build-bindings.sh`.** With it,
  the proc-macro dylibs cargo builds for the host are refused by dyld on macOS 27
  ("mis-aligned LINKEDIT string pool").
- **Signing.** `apple/signing.env` (not in git) sets `SIGN_ID`, `INSTALLER_ID` and
  `NOTARY_PROFILE`; without it the build is ad hoc, as in CI, and its identity changes with
  each build, so macOS asks again for notifications, the login item and Keychain access.
  Apple notarizes the `.pkg` only when it is signed with a "Developer ID Installer"
  certificate (`INSTALLER_ID`), a different one from the app's. Notarization needs the
  Hardened Runtime and a secure timestamp (both in `package.sh`), and Apple's answer took
  more than twenty minutes on the first submission: `dev:package` has a two-hour timeout
  for that reason. If it is cut short, read the verdict with
  `xcrun notarytool info <id> --keychain-profile wattsup` and staple the package by hand
  with `xcrun stapler staple`.
- **Sparkle's key.** Updates are signed with the EdDSA key of account `wattsup` in the
  login Keychain; `SUPublicEDKey` in `apple/Info.plist` is its public half. Every
  installed copy trusts that key only: a new key means no more updates for them.
  `release.sh` checks the two halves match before building.
- **`._` entries in the package.** macOS tags files written by some processes with
  `com.apple.provenance`, which `xattr -c` cannot remove; `pkgbuild` stores it as `._`
  entries. They come back as attributes on install and do not touch the seal:
  `package.sh` verifies the app expanded from the package (`pkgutil --expand-full`).
- **Notifications need the bundle.** Under `swift run` there is no bundle identifier and
  `Notifier` does nothing.
