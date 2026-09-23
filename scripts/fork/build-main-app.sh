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
signing_identity="TypeWhisper Fork Local Signing"
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

built="$derived/Build/Products/Debug/TypeWhisper.app"
printf 'branch=%s\ncommit=%s\n' "$branch" "$commit" > "$built/Contents/Resources/FeatureBuildSource.txt"

# Stage outside the checkout: files under ~/Desktop pick up Finder/iCloud
# metadata that codesign rejects ("resource fork ... detritus not allowed").
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT
ditto --noextattr --norsrc "$built" "$staging_dir/TypeWhisper.app"
built="$staging_dir/TypeWhisper.app"

if security find-identity -v -p codesigning | grep -qF "\"$signing_identity\""; then
  log "signing with \"$signing_identity\""
  codesign --force --deep --sign "$signing_identity" --timestamp=none "$built"
  codesign --verify --deep --strict "$built"
else
  log "warning: \"$signing_identity\" not found; run scripts/fork/setup-local-signing.sh once."
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
fi
ditto "$built" "$install_path"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$install_path"
log "installed $install_path (${commit:0:8})"
codesign -d -r- "$install_path" 2>&1 | sed -n 's/^designated => /[main-app] designated requirement: /p'
