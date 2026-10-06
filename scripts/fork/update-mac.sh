#!/usr/bin/env bash
# Bring this Mac's main app up to date with the fork's main branch in one step:
# pull main, snapshot the current configuration, rebuild and install the app,
# rebuild its plugins, and relaunch it. Settings and Keychain items are kept.
#
# Usage:
#   scripts/fork/update-mac.sh                    # routine update
#   scripts/fork/update-mac.sh --import-settings  # also take the settings exported on the other Mac
#
# First run on a new Mac: see "Using the app on another Mac" in FORK.md.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_support_name="TypeWhisper-Dev-main"
app_dir="$HOME/Library/Application Support/$app_support_name"
install_path="$HOME/Applications/TypeWhsiper-main.app"
import_settings=false

log() { printf '[update-mac] %s\n' "$*"; }
die() { printf '[update-mac] error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --import-settings) import_settings=true; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

cd "$repo_root"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "switch to main first"
[[ -z "$(git status --porcelain)" ]] || die "the checkout has uncommitted changes"
log "pulling main"
git pull -q --ff-only origin main
log "now at $(git log -1 --format='%h %s')"

[[ -d "$app_dir" ]] && scripts/fork/snapshot-app-state.sh --message "before update-mac $(git rev-parse --short HEAD)"

scripts/fork/build-main-app.sh

if $import_settings; then
  scripts/fork/settings-sync.sh import
fi

# Rebuild installed plugins; on a fresh Mac, install the ones the settings list.
declare -a add=()
if [[ -f "$HOME/TypeWhisper-settings/main/plugins.txt" ]] && $import_settings; then
  while IFS= read -r plugin; do
    [[ -z "$plugin" || -e "$app_dir/Plugins/$plugin.bundle" ]] && continue
    if [[ -f "TypeWhisperPluginSDK/Plugins/$plugin/manifest.json" ]]; then
      add+=(--add "$plugin")
    else
      log "install $plugin from Integrations > Discover (not built from this repo)"
    fi
  done < "$HOME/TypeWhisper-settings/main/plugins.txt"
fi
if compgen -G "$app_dir/Plugins/*.bundle" >/dev/null || [[ ${#add[@]} -gt 0 ]]; then
  scripts/fork/install-plugins.sh --app-support "$app_support_name" "${add[@]+"${add[@]}"}"
fi

open "$install_path"
log "done; the app is running"
