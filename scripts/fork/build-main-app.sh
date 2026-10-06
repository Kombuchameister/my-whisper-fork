#!/usr/bin/env bash
# Build the fork's main developer app from the current checkout and install it
# over the existing one, keeping its isolated identity and all settings:
#   bundle ID      com.typewhisper.mac.dev.main
#   app support    ~/Library/Application Support/TypeWhisper-Dev-main
#   prefs domain   com.typewhisper.mac.dev.main
# /Applications/TypeWhisper.app (the upstream production fallback) is never touched.
#
# Usage: scripts/fork/build-main-app.sh [--install-path ~/Applications/TypeWhsiper-main.app]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
slug="main"
bundle_id="com.typewhisper.mac.dev.main"
install_path="$HOME/Applications/TypeWhsiper-main.app"
local_signing_identity="TypeWhisper Fork Local Signing"
derived="$repo_root/.build/DerivedData-MainApp"
archive_dir="$HOME/TypeWhisper-archives/apps"

log() { printf '[main-app] %s\n' "$*"; }
die() { printf '[main-app] error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-path) install_path="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$install_path" != /Applications/TypeWhisper.app* ]] || die "refusing to overwrite the production app"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
commit="$(git -C "$repo_root" rev-parse HEAD)"
[[ "$branch" == "main" ]] || log "warning: building from '$branch', not main"
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] || log "warning: working tree has uncommitted changes"

products="$derived/Build/Products/Debug"
# Remove earlier app products so a stale bundle can never be installed. Upstream
# renamed the Debug product ("TypeWhisper Dev.app"), which once made this script
# keep installing an old "TypeWhisper.app" left in DerivedData.
rm -rf "$products"/TypeWhisper*.app

log "building $branch @ ${commit:0:8}"
xcodebuild build -skipPackagePluginValidation -skipMacroValidation \
  -project "$repo_root/TypeWhisper.xcodeproj" -scheme TypeWhisper -configuration Debug \
  -derivedDataPath "$derived" -destination 'generic/platform=macOS' \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  TYPEWHISPER_DISPLAY_NAME="TypeWhisper Feature - $slug" \
  TYPEWHISPER_FEATURE_SLUG="$slug" \
  TYPEWHISPER_ICLOUD_ENABLED=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  > "$repo_root/.build/main-app-build.log" 2>&1 \
  || die "build failed; see .build/main-app-build.log"

# The app product is whichever bundle carries the main app's bundle ID.
built=""
for app in "$products"/*.app; do
  [[ -d "$app" ]] || continue
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" == "$bundle_id" ]]; then
    built="$app"
  fi
done
[[ -n "$built" ]] || die "build produced no app with bundle ID $bundle_id in $products"
log "built $(basename "$built")"
printf 'branch=%s\ncommit=%s\n' "$branch" "$commit" > "$built/Contents/Resources/FeatureBuildSource.txt"

# Stage outside the checkout: files under ~/Desktop pick up Finder/iCloud
# metadata that codesign rejects ("resource fork ... detritus not allowed").
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT
ditto --noextattr --norsrc "$built" "$staging_dir/TypeWhisper.app"
built="$staging_dir/TypeWhisper.app"

# Prefer an Apple Development certificate: its Team ID gives Keychain items a
# stable partition ("teamid:…"), so rebuilds never prompt again. The local
# self-signed identity has no Team ID; Keychain then pins each build's code
# hash and asks once per key after every rebuild. Sign by SHA-1 so a renewed
# certificate next to an expiring one is not ambiguous (newest listed last).
identities="$(security find-identity -v -p codesigning)"
signing_hash="$(printf '%s\n' "$identities" | awk '/"Apple Development: /{h=$2} END{print h}')"
if [[ -n "$signing_hash" ]]; then
  signing_name="$(printf '%s\n' "$identities" | awk -v h="$signing_hash" '$2==h{sub(/^[^"]*"/,""); sub(/"$/,""); print}')"
elif printf '%s\n' "$identities" | grep -qF "\"$local_signing_identity\""; then
  signing_hash="$local_signing_identity"
  signing_name="$local_signing_identity"
  log "warning: no Apple Development certificate; Keychain will ask once per key after each rebuild."
  log "         Sign in to Xcode (Settings > Accounts) to create one."
fi

if [[ -n "$signing_hash" ]]; then
  log "signing with \"$signing_name\""
  codesign --force --deep --sign "$signing_hash" --timestamp=none "$built"
  codesign --verify --deep --strict "$built"
else
  log "warning: no signing identity; run scripts/fork/setup-local-signing.sh once."
  log "         Unsigned builds make Keychain ask again after every rebuild."
fi

if pgrep -f "$install_path/Contents/MacOS/TypeWhisper" >/dev/null; then
  log "quitting the running main app"
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for _ in {1..40}; do pgrep -f "$install_path/Contents/MacOS/TypeWhisper" >/dev/null || break; sleep 0.25; done
fi

if [[ -d "$install_path" ]]; then
  mkdir -p "$archive_dir"
  previous="$archive_dir/$(basename "$install_path" .app)-$(date +%Y%m%d-%H%M%S).app"
  mv "$install_path" "$previous"
  log "previous app moved to $previous"
  # Keep only the three most recent previous builds (about 160 MB each). Sort
  # by the timestamp in the name: ditto keeps the build product's mtime, so
  # every archive has the same modification time.
  ls -1d "$archive_dir/$(basename "$install_path" .app)"-*.app 2>/dev/null | sort -r | tail -n +4 | while IFS= read -r old; do
    rm -rf "$old"
    log "pruned old build $(basename "$old")"
  done
fi
ditto "$built" "$install_path"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$install_path"
log "installed $install_path (${commit:0:8})"
codesign -d -r- "$install_path" 2>&1 | sed -n 's/^designated => /[main-app] designated requirement: /p'
