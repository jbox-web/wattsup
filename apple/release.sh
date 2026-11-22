#!/bin/sh
# Publishes a release of Watt's Up:
#   1. builds, signs and notarizes the app and its installer (apple/package.sh, settings
#      in apple/signing.env);
#   2. signs the package for Sparkle (EdDSA, private key of account "wattsup" in the login
#      Keychain) and writes appcast.xml, which lists this version;
#   3. tags the commit built (annotated, signed) and pushes the tag;
#   4. creates the GitHub Release vVERSION with WattsUp-VERSION.pkg and appcast.xml.
#
# The app reads the appcast.xml of the latest Release (SUFeedURL), so each Release carries
# its own.
#
#   apple/release.sh             all four steps, for the version in Cargo.toml
#   NOTES=file apple/release.sh  the same, with release notes (Markdown) for the Release
#                                and the appcast (rendered to HTML by GitHub's Markdown API)
#
# REPO (default jbox-web/wattsup) names the GitHub repository. The commit must be on the
# remote already; the tag and the Release must not exist yet.
set -eu
cd "$(dirname "$0")/.."
REPO=${REPO:-jbox-web/wattsup}
export REPO
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
[ -n "$VERSION" ] || { echo "no version in Cargo.toml" >&2; exit 1; }
tag="v$VERSION"
pkg="apple/dist/WattsUp-$VERSION.pkg"
sparkle=apple/.build/artifacts/sparkle/Sparkle/bin
# gh writes with its own Keychain token, not a GITHUB_TOKEN the shell may export.
gh() { env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"; }

# Any argument stops here: a typo must not publish a release.
[ $# -eq 0 ] || { echo "usage: [NOTES=file] $0" >&2; exit 2; }
if [ -n "${NOTES:-}" ] && [ ! -f "$NOTES" ]; then
  echo "NOTES=$NOTES: no such file" >&2
  exit 1
fi
# A failed call to GitHub must not read as "no such release" below.
gh repo view "$REPO" --json name >/dev/null
# Release notes, appcast and the downloaded package: one directory, removed at exit.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The commit built and tagged, fixed now: the build takes long enough for HEAD to move.
commit=$(git rev-parse HEAD)
# Before the clean-tree check: a resolve that rewrote Package.resolved would otherwise be
# seen only after the build and the notarization.
swift package --package-path apple resolve >/dev/null
# Untracked files count: SwiftPM compiles every file of a target's directory.
if [ -n "$(git status --porcelain)" ]; then
  echo "uncommitted or untracked changes: commit them before releasing" >&2
  exit 1
fi
if [ "$(git branch --show-current)" != master ]; then
  echo "releases are cut from master" >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "$tag" >/dev/null; then
  echo "tag $tag exists already: raise the version in Cargo.toml, or finish by hand" >&2
  exit 1
fi
if [ -n "$(gh release list --repo "$REPO" --json tagName --jq ".[] | select(.tagName == \"$tag\") | .tagName")" ]; then
  echo "release $tag exists already in $REPO: raise the version in Cargo.toml" >&2
  exit 1
fi
git fetch -q origin
if ! git merge-base --is-ancestor "$commit" origin/master; then
  echo "push $(git rev-parse --short "$commit") first: the Release must point at a published commit" >&2
  exit 1
fi
# Checked before the build: notarization alone can take more than twenty minutes.
if [ ! -f apple/signing.env ]; then
  echo "apple/signing.env is missing: a release must be signed and notarized" >&2
  exit 1
fi
# shellcheck disable=SC1091
. apple/signing.env
for setting in SIGN_ID INSTALLER_ID NOTARY_PROFILE; do
  eval "value=\${$setting:-}"
  # shellcheck disable=SC2154
  [ -n "$value" ] || { echo "$setting is not set in apple/signing.env: a release must be signed and notarized" >&2; exit 1; }
done
# Updates signed with another key than the one the app trusts would be refused by every
# installed copy.
trusted=$(plutil -extract SUPublicEDKey raw apple/Info.plist)
held=$("$sparkle/generate_keys" --account wattsup -p) || {
  echo "no Sparkle signing key for account wattsup in the login Keychain" >&2
  exit 1
}
if [ "$held" != "$trusted" ]; then
  echo "the Sparkle key in the Keychain is not the one apple/Info.plist trusts" >&2
  exit 1
fi

echo "== Build, sign, notarize"
apple/package.sh
spctl --assess --type install "$pkg"
if [ "$(git rev-parse HEAD)" != "$commit" ] || [ -n "$(git status --porcelain)" ]; then
  echo "the repository changed during the build: nothing published" >&2
  exit 1
fi
build=$(cat apple/dist/build-number)
min_os=$(plutil -extract LSMinimumSystemVersion raw apple/Info.plist)

echo "== Appcast"
# sparkle:edSignature="..." length="..."
signature=$("$sparkle/sign_update" --account wattsup "$pkg")
notes="$work/notes.md"
{
  if [ -n "${NOTES:-}" ]; then
    cat "$NOTES"
    printf '\n'
  fi
  echo "Signed with a Developer ID and notarized by Apple. macOS $min_os or later."
} > "$notes"
# Sparkle shows the description as HTML: the Markdown is rendered by GitHub, as on the
# Release's page, in the system font and appearance.
html=$(gh api -X POST markdown -f mode=markdown -F text=@"$notes")
style='<style>:root{color-scheme:light dark}body{font:13px -apple-system,sans-serif;margin:0 8px}h2{font-size:15px;margin:14px 0 6px}ul{padding-left:20px}li{margin:3px 0}code{font:12px ui-monospace,monospace}.anchor{display:none}</style>'
description="<description><![CDATA[$style$(printf '%s' "$html" | sed 's/]]>/]] >/g')]]></description>"
url="https://github.com/$REPO/releases/download/$tag/WattsUp-$VERSION.pkg"
appcast="$work/appcast.xml"
cat > "$appcast" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Watt's Up</title>
    <item>
      <title>Watt's Up $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/$tag</link>
      $description
      <enclosure url="$url" type="application/octet-stream" sparkle:installationType="package" $signature/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$appcast"

echo "== Tag $tag"
git tag -s "$tag" -m "Release $VERSION" "$commit"
git tag -v "$tag"
git push origin "$tag"

echo "== Release $tag"
# A draft first: once published it is the latest Release, whose appcast.xml every installed
# app reads, so what it serves is checked before.
gh release create "$tag" "$pkg" "$appcast" --repo "$REPO" --verify-tag --draft --title "Watt's Up $VERSION" --notes-file "$notes"
# What the Release serves must be the package just built and signed for Sparkle: GitHub's
# digest of the asset, and the asset downloaded back, against the local file.
sha=$(shasum -a 256 "$pkg" | cut -d' ' -f1)
digest=$(gh release view "$tag" --repo "$REPO" --json assets \
  --jq ".assets[] | select(.name == \"WattsUp-$VERSION.pkg\") | .digest")
gh release download "$tag" --repo "$REPO" --pattern "WattsUp-$VERSION.pkg" --dir "$work"
if [ "$digest" != "sha256:$sha" ] || [ "$(shasum -a 256 "$work/WattsUp-$VERSION.pkg" | cut -d' ' -f1)" != "$sha" ]; then
  echo "the package served by the draft Release ($digest) is not the one just built ($sha): left as a draft" >&2
  exit 1
fi
gh release edit "$tag" --repo "$REPO" --draft=false --latest
echo "published: https://github.com/$REPO/releases/tag/$tag"
