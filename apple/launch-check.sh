#!/bin/sh
# Starts an assembled app for a few seconds and fails if it quits: a crash at launch must
# stop a release, not reach users (0.1.1 stopped at launch on a missing resource bundle,
# which no test could see). Runs on an empty configuration of its own and trial Keychain
# entries, so it touches nothing of the user's.
# Usage: launch-check.sh <path to the .app>
set -eu
app=$1
executable="$app/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")"
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
WATTSUP_CONFIG="$probe/config.toml" "$executable" > "$probe/output.log" 2>&1 &
pid=$!
sleep 5
# A Swift fatal error does not end the process at once: it stays alive for many seconds
# while macOS writes its crash report. Its message is what tells.
crashed=no
grep -qE 'Fatal error|Terminating app due to uncaught exception' "$probe/output.log" && crashed=yes
if [ "$crashed" = yes ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "the app crashed or quit within 5 seconds of launch:" >&2
  cat "$probe/output.log" >&2
  kill -9 "$pid" 2>/dev/null || true
  exit 1
fi
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
echo "launch check: still running after 5 seconds"
