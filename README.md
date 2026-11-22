# Watt's Up

[![CI](https://github.com/jbox-web/wattsup/actions/workflows/ci.yml/badge.svg)](https://github.com/jbox-web/wattsup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Watches UPSes served by [NUT](https://networkupstools.org/) servers (`upsd`) from a Mac:
a menu bar icon, a window, notifications, a line in the macOS **Batteries** widget, and
a command-line tool. Read-only: it never sends a command to a UPS and never shuts
anything down.

A typical setup is a UPS plugged into a NAS that runs the NUT server; this app talks to
that server over TCP (port 3493). A UPS plugged into the Mac by USB is not its business:
macOS already shows those.

## Install

Download `WattsUp-<version>.pkg` from the
[Releases](https://github.com/jbox-web/wattsup/releases) and open it. It installs
`Watt's Up.app` in `/Applications` and links the `wattsup` command into `/usr/local/bin`.
The app is universal (Apple Silicon and Intel), needs macOS 14 or later, and is signed and
notarized by Apple.

After that the app updates itself: it checks the latest Release once a day and offers a new
version, installed only once you accept (your administrator password is asked). The menu
has "Check for Updates…", and Settings can turn the daily check off.

Installed with Homebrew before 0.2.0? The cask is gone: run
`brew uninstall --cask wattsup`, then install the package.

## Build from source

Needs Rust, Xcode 27 with its command-line tools (the universal release build does not
link with Xcode 26), and [mise](https://mise.jdx.dev/).

```sh
mise run dev:package   # builds apple/dist/Watt's Up.app
mise run dev:install   # quits the running app and copies the new one to /Applications
open "/Applications/Watt's Up.app"
```

Without settings the app is signed ad hoc, which is enough to run it on the Mac that
built it. To distribute it, sign it with a Developer ID certificate and have Apple
notarize it: put the three settings in `apple/signing.env` (kept out of git), and
`dev:package` does the rest.

```sh
SIGN_ID="Developer ID Application: <team name>"
# Signs the .pkg: Apple notarizes no package without it.
INSTALLER_ID="Developer ID Installer: <team name>"
NOTARY_PROFILE=wattsup     # made once by: xcrun notarytool store-credentials wattsup --apple-id <id> --team-id <team>
```

The app and the CLI are universal (Apple Silicon and Intel), for macOS 14 or later.
The app is then signed with the Hardened Runtime and a secure timestamp and put in the
installer `apple/dist/WattsUp-<version>.pkg`; the package is signed, sent to Apple, and the
ticket is stapled to it. Apple's answer can take more than twenty minutes. A stable
identity also keeps the notification permission, the login item and Keychain access from
one build to the next; an ad hoc one changes with every build. Without `INSTALLER_ID` the
package is left unsigned, which is enough to try it on the Mac that built it.

`mise run dev:release` publishes the version of `Cargo.toml`: it builds, signs and
notarizes the package, signs it for Sparkle, pushes a signed tag, and creates the GitHub
Release with the package and its `appcast.xml`, the feed the installed apps read. Release
notes in Markdown go in a file: `NOTES=notes.md mise run dev:release`; they show on the
Release and in the app's update window. The commit must be pushed first.

Updates are signed with an EdDSA key whose private half lives in the login Keychain
(account `wattsup`) and whose public half is `SUPublicEDKey` in `apple/Info.plist`. It was
made once by Sparkle's `generate_keys --account wattsup` (in
`apple/.build/artifacts/sparkle/Sparkle/bin/` once the package is resolved). Lose it and the
installed apps refuse every later update: export it (`generate_keys --account wattsup -x
<file>`) and keep it somewhere safe. `dev:release` checks the two halves match before
building.

Other tasks: `dev:test` and `dev:swift-test` (tests), `dev:lint`, `dev:fmt-check`,
`dev:bindings` (Rust library and Swift bindings only).

## The app

It lives in the menu bar and has no Dock icon.

- **Menu bar icon** — the worst state of all UPSes: plain when everything is on mains,
  orange when one is on battery, red when one cannot be reached. Its menu lists each UPS.
- **Window** — every UPS with its state, charge, runtime and load, and all the variables
  its NUT server reports.
- **Settings** — add, edit and remove UPSes ("Test connection" lists the UPS names a
  server offers), the poll interval, notifications (with a warning and a link to System
  Settings when macOS blocks them), opening at login.
- **Notifications** — on battery, battery low, back on mains, unreachable, reachable
  again, no fresh data, request refused by the server (access denied, unknown UPS name),
  battery to replace. Nothing is notified at launch: only changes.
  A UPS is declared unreachable after three failed polls in a row, and failures are
  ignored while the Mac itself has no network or has just woken up.

### The Batteries widget

Each UPS with "Show in the Batteries widget" on appears as a line in Apple's own
Batteries widget, while the app runs. Three things to know:

- It relies on **private macOS functions** (`IOPSCreatePowerSource` and friends). A macOS
  update can break it. If macOS refuses, the app stops publishing and everything else
  keeps working.
- The widget has no notion of a UPS. The line is published as an accessory of category
  "Battery Case", which is what gives it its small plug icon. It is deliberately *not*
  published as a UPS: macOS would then believe the Mac itself runs on that UPS and switch
  to its battery energy settings when the remote UPS loses mains power.
- The widget shows a limited number of lines (six at the size it was tried with); with
  many Bluetooth devices, not every UPS will fit.

## Configuration

`~/.config/wattsup/config.toml` (or `$XDG_CONFIG_HOME/wattsup/config.toml`),
shared by the app and the CLI. The settings window writes it; it can also be edited by
hand: the app reads it at launch, so restart it after a hand edit. A change made in the
settings is applied to the file as it is on disk at that moment, so an entry added by
hand is kept; comments are not. A file that cannot be read is never overwritten: the
app shows the error and waits for it to be fixed.

```toml
poll_interval_seconds = 30       # default 30, minimum 5

[[ups]]
name = "Home"                    # display name, unique
host = "192.0.2.10"
port = 3493                      # default 3493
ups = "ups"                      # the UPS name on the NUT server
publish = true                   # show in the Batteries widget (default true)
notify_unreachable = true        # default true
username = "monuser"             # only if the server asks for one
```

A password never goes in this file: it lives in the macOS Keychain, as the generic
password of service `jbox.wattsup.<name>` and account `<username>`. The settings
window stores it; by hand (the app reads it at each poll, no restart needed):

```sh
security add-generic-password -U -s jbox.wattsup.Home -a monuser -w
```

The app reads the password once, at its first poll after launch or after a settings
change. When the Keychain refuses to give it, the UPS shows "password not readable from
the Keychain". A password missing from the Keychain means a poll without credentials, as
in the CLI, which warns about it and goes on with the other UPSes.

Authentication has only been exercised against the fake server of the test suite: none
of the servers this was developed with asks for one. TLS (`STARTTLS`) is not supported.

`WATTSUP_CONFIG=/path/to/config.toml` makes the app read another file, for trials. Its
passwords then go under `jbox.wattsup-trial.<name>`, apart from the real ones.

## Command line

The app bundle contains the CLI, `/Applications/Watt's Up.app/Contents/MacOS/wattsup`; the
package links it as `/usr/local/bin/wattsup`.

```console
$ wattsup status
NAME    STATE        CHARGE  RUNTIME  LOAD
Home    on mains     100%    47m      10%
Office  unreachable  -       -        -

$ wattsup vars Home          # every variable, in the format of upsc
battery.charge: 100
battery.runtime: 2858
...

$ wattsup list 192.0.2.10  # the UPS names a server offers; needs no configuration
ups  Description unavailable
```

`--json` prints JSON instead, `--config <path>` reads another configuration file. Exit
status: 0, 1 when a UPS is unreachable, has no data or is refused by its server, 2 on a
usage or configuration error. The CLI does not feed the Batteries widget: a published
line lives only as long as the process that published it.

## Layout

```
crates/wattsup-core   NUT client, model, state changes, configuration, power sources
crates/wattsup-ffi    what the app sees of the core, through UniFFI
crates/cli            the wattsup binary
crates/test-support   a fake upsd for tests, also runnable (cargo run -p test-support --bin fake-upsd)
apple/                the macOS app: SwiftPM package, build and packaging scripts
```

To watch the app react without pulling a plug, run the fake server and point an entry of
a trial configuration at it:

```sh
cargo run -p test-support --bin fake-upsd -- 34930 "OL:40" "OB DISCHRG:60" "OL:600"
```

## License

[MIT](LICENSE).
