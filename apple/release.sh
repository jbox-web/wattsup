#!/bin/sh
# Publishes a release of Watt's Up:
#   1. builds, signs and notarizes the app (apple/package.sh, settings in apple/signing.env);
#   2. tags the commit built (annotated, signed) and pushes the tag;
#   3. creates the GitHub Release vVERSION with apple/dist/WattsUp-VERSION.zip;
#   4. writes Casks/wattsup.rb in the jbox-web/homebrew-tap tap and pushes it.
#
# Nothing in the tap is written by hand: this script is to the cask what crystalreleaser
# is to the tap's formulae. The cask is the only file it touches there.
#
#   apple/release.sh             all four steps, for the version in Cargo.toml
#   apple/release.sh --cask      step 4 only, for a Release already published
#
# REPO (default jbox-web/wattsup) and TAP (default jbox-web/homebrew-tap) name the GitHub
# repositories. The commit must be on the remote already; the tag and the Release must
# not exist yet.
set -eu
cd "$(dirname "$0")/.."
REPO=${REPO:-jbox-web/wattsup}
TAP=${TAP:-jbox-web/homebrew-tap}
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
[ -n "$VERSION" ] || { echo "no version in Cargo.toml" >&2; exit 1; }
tag="v$VERSION"
archive="apple/dist/WattsUp-$VERSION.zip"
# gh writes with its own Keychain token, not a GITHUB_TOKEN the shell may export.
gh() { env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"; }

# Anything but no argument or --cask stops here: a typo must not publish a release.
cask_only=no
case "${1:-}" in
  "") ;;
  --cask) cask_only=yes ;;
  *) echo "usage: $0 [--cask]" >&2; exit 2 ;;
esac
# A failed call to GitHub must not read as "no such release" below.
gh repo view "$REPO" --json name >/dev/null
# Release notes, the downloaded archive and the tap clone: one directory, removed at exit.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "$cask_only" = no ]; then
  # The commit built and tagged, fixed now: the build takes long enough for HEAD to move.
  commit=$(git rev-parse HEAD)
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
  if [ ! -f apple/signing.env ]; then
    echo "apple/signing.env is missing: a release must be signed and notarized" >&2
    exit 1
  fi

  echo "== Build, sign, notarize"
  apple/package.sh
  spctl --assess --type execute "apple/dist/Watt's Up.app"
  if [ "$(git rev-parse HEAD)" != "$commit" ] || [ -n "$(git status --porcelain)" ]; then
    echo "the repository changed during the build: nothing published" >&2
    exit 1
  fi

  echo "== Tag $tag"
  git tag -s "$tag" -m "Release $VERSION" "$commit"
  git tag -v "$tag"
  git push origin "$tag"

  echo "== Release $tag"
  sha=$(shasum -a 256 "$archive" | cut -d' ' -f1)
  notes="$work/notes.md"
  cat > "$notes" <<NOTES
Universal app (Apple Silicon and Intel), macOS 14 or later, signed with a Developer ID
certificate and notarized by Apple. The \`wattsup\` CLI is inside the bundle.

Install: \`brew install --cask jbox-web/tap/wattsup\`, or unzip \`WattsUp-$VERSION.zip\` and
move \`Watt's Up.app\` to \`/Applications\`.

SHA-256 of \`WattsUp-$VERSION.zip\`: \`$sha\`
NOTES
  gh release create "$tag" "$archive" --repo "$REPO" --verify-tag --title "Watt's Up $VERSION" --notes-file "$notes"
fi

echo "== Cask"
# The checksum of what the Release serves, not of a local file that may differ.
download="$work"
gh release download "$tag" --repo "$REPO" --pattern "WattsUp-$VERSION.zip" --dir "$download"
sha=$(shasum -a 256 "$download/WattsUp-$VERSION.zip" | cut -d' ' -f1)
# GitHub's own digest of the asset, and in a full release the archive just built: all
# three must agree before the cask goes out.
digest=$(gh release view "$tag" --repo "$REPO" --json assets \
  --jq ".assets[] | select(.name == \"WattsUp-$VERSION.zip\") | .digest")
if [ "$digest" != "sha256:$sha" ]; then
  echo "the archive downloaded ($sha) does not match GitHub's digest ($digest)" >&2
  exit 1
fi
if [ "$cask_only" = no ] && [ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" != "$sha" ]; then
  echo "the archive served by the Release is not the one just built" >&2
  exit 1
fi
git clone -q --depth 1 "git@github.com:$TAP.git" "$download/tap"
mkdir -p "$download/tap/Casks"
apple/cask.rb.sh "$VERSION" "$sha" "$REPO" > "$download/tap/Casks/wattsup.rb"
cd "$download/tap"
if git diff --quiet -- Casks/wattsup.rb && git ls-files --error-unmatch Casks/wattsup.rb >/dev/null 2>&1; then
  echo "Casks/wattsup.rb is already at $VERSION"
  exit 0
fi
git add Casks/wattsup.rb
git commit -q -m "Brew cask update for wattsup version $tag"
git push -q origin HEAD
echo "cask wattsup $VERSION pushed to $TAP"
