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

```sh
brew install --cask jbox-web/tap/wattsup
```

Or download `WattsUp-<version>.zip` from the
[Releases](https://github.com/jbox-web/wattsup/releases), unzip it and move
`Watt's Up.app` to `/Applications`. The app is universal (Apple Silicon and Intel),
needs macOS 14 or later, and is signed and notarized by Apple.

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
notarize it: put the two settings in `apple/signing.env` (kept out of git), and
`dev:package` does the rest.

```sh
SIGN_ID="Developer ID Application: <team name>"
NOTARY_PROFILE=wattsup     # made once by: xcrun notarytool store-credentials wattsup --apple-id <id> --team-id <team>
```

The app and the CLI are universal (Apple Silicon and Intel), for macOS 14 or later.
The app is then signed with the Hardened Runtime and a secure timestamp, sent to Apple,
and the ticket is stapled to it. `apple/dist/WattsUp-<version>.zip` is the archive to
publish. Apple's answer can take more than twenty minutes. A stable identity also keeps
the notification permission, the login item and Keychain access from one build to the
next; an ad hoc one changes with every build.

`mise run dev:release` publishes the version of `Cargo.toml`: it builds, signs and
notarizes the app, pushes a signed tag, creates the GitHub Release with the archive, and
writes the `wattsup` cask into [jbox-web/homebrew-tap](https://github.com/jbox-web/homebrew-tap).
The commit must be pushed first. `apple/release.sh --cask` redoes the last step alone.

Other tasks: `dev:test` and `dev:swift-test` (tests), `dev:lint`, `dev:fmt-check`,
`dev:bindings` (Rust library and Swift bindings only).

## The app

It lives in the menu bar and has no Dock icon.

- **Menu bar icon** — the worst state of all UPSes: plain when everything is on mains,
  orange when one is on battery, red when one cannot be reached. Its menu lists each UPS.
- **Window** — every UPS with its state, charge, runtime and load, and all the variables
  its NUT server reports.
- **Settings** — add, edit and remove UPSes ("Test connection" lists the UPS names a
  server offers), the poll interval, notifications, opening at login.
- **Notifications** — on battery, battery low, back on mains, unreachable, reachable
  again, no fresh data, battery to replace. Nothing is notified at launch: only changes.
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
window stores it; by hand (the app reads passwords at launch):

```sh
security add-generic-password -U -s jbox.wattsup.Home -a monuser -w
```

Authentication has only been exercised against the fake server of the test suite: none
of the servers this was developed with asks for one. TLS (`STARTTLS`) is not supported.

`WATTSUP_CONFIG=/path/to/config.toml` makes the app read another file, for trials.

## Command line

The app bundle contains the CLI: `/Applications/Watt's Up.app/Contents/MacOS/wattsup`.

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
status: 0, 1 when a UPS is unreachable or has no data, 2 on a usage or configuration
error. The CLI does not feed the Batteries widget: a published line lives only as long
as the process that published it.

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
