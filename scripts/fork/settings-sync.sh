#!/usr/bin/env bash
# Carry the main app's configuration between Macs through a private git repo.
#
# Usage:
#   scripts/fork/settings-sync.sh export   # on the Mac whose settings you changed
#   scripts/fork/settings-sync.sh import   # on the other Mac (quits the app first)
# Options:
#   --repo <dir>          local clone (default ~/TypeWhisper-settings)
#   --remote <owner/name> GitHub repo created private on first export
#                         (default Kombuchameister/typewhisper-settings)
#
# Synced: the preferences domain (minus machine-specific keys), the workflows,
# profiles, prompt-actions, snippets and dictionary stores, small plugin
# configuration files, and the list of installed plugins.
# Not synced: Keychain secrets (enter API keys once per Mac; import lists the
# missing ones), history, usage statistics, audio, and models.
# Import keeps the replaced files under <app-support>/settings-sync.replaced/.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_support_name="TypeWhisper-Dev-main"
domain="com.typewhisper.mac.dev.main"
install_path="$HOME/Applications/TypeWhsiper-main.app"
sync_repo="$HOME/TypeWhisper-settings"
remote="Kombuchameister/typewhisper-settings"
stores=(workflows profiles prompt-actions snippets dictionary)

log() { printf '[settings-sync] %s\n' "$*"; }
die() { printf '[settings-sync] error: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 ]] || { sed -n '2,17p' "$0"; exit 1; }
mode="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) sync_repo="$2"; shift 2 ;;
    --remote) remote="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

app_dir="$HOME/Library/Application Support/$app_support_name"
data_dir="$sync_repo/main"

ensure_repo() {
  if [[ -d "$sync_repo/.git" ]]; then
    git -C "$sync_repo" pull -q --ff-only || die "could not update $sync_repo; resolve it manually"
    return
  fi
  if gh repo view "$remote" >/dev/null 2>&1; then
    git clone -q "https://github.com/$remote.git" "$sync_repo"
  elif [[ "$mode" == "export" ]]; then
    log "creating private repository $remote"
    gh repo create "$remote" --private \
      --description "TypeWhisper settings synced between Macs (scripts/fork/settings-sync.sh)" >/dev/null
    git clone -q "https://github.com/$remote.git" "$sync_repo" 2>/dev/null || {
      mkdir -p "$sync_repo"; git -C "$sync_repo" init -q -b main
      git -C "$sync_repo" remote add origin "https://github.com/$remote.git"
    }
  else
    die "no settings repository $remote yet; run export on the other Mac first"
  fi
}

quit_app() {
  if pgrep -f "$install_path/Contents/MacOS/TypeWhisper" >/dev/null; then
    log "quitting the main app"
    osascript -e "tell application id \"$domain\" to quit" >/dev/null 2>&1 || true
    for _ in {1..40}; do
      pgrep -f "$install_path/Contents/MacOS/TypeWhisper" >/dev/null || return 0
      sleep 0.25
    done
    die "the main app is still running; quit it and try again"
  fi
}

# Preferences that describe this Mac rather than your configuration.
prefs_filter='
import plistlib, re, sys
EXCLUDE = re.compile(
    r"^(NS|LiveTranscriptPanelFrame|SU)"           # window frames, panels, Sparkle state
    r"|^(lastSeenReleaseFingerprint|lastAcknowledgedPostUpdatePromptRelease)$"
    r"|^pluginRegistryLast"                         # catalog check timestamps
    r"|^premium\.account\.deviceID$|^premiumSync\." # per-device identifiers
    r"|^selectedIntegrationTab$"
    r"|^plugin\.com\.typewhisper\.openai\.oauth"   # ChatGPT login (its tokens live in Keychain)
    r"|\.loadedModel$"                              # models loaded on this Mac
)
'

export_settings() {
  [[ -d "$app_dir" ]] || die "no app data at $app_dir"
  ensure_repo
  rm -rf "$data_dir"
  mkdir -p "$data_dir/stores" "$data_dir/plugin-data"

  defaults export "$domain" - | python3 -c "$prefs_filter"'
data = plistlib.loads(sys.stdin.buffer.read())
home = sys.argv[1]
def rehome(value):
    if isinstance(value, str) and (value == home or value.startswith(home + "/")):
        return "$HOME" + value[len(home):]
    return value
kept = {k: rehome(v) for k, v in data.items() if not EXCLUDE.search(k)}
sys.stdout.buffer.write(plistlib.dumps(kept, fmt=plistlib.FMT_XML, sort_keys=True))
' "$HOME" > "$data_dir/preferences.plist"

  for store in "${stores[@]}"; do
    [[ -f "$app_dir/$store.store" ]] || continue
    sqlite3 -readonly "$app_dir/$store.store" .dump > "$data_dir/stores/$store.sql"
  done

  # Plugin configuration lives in top-level files of PluginData/<plugin id>/;
  # subdirectories hold models and downloads and stay on each Mac.
  if [[ -d "$app_dir/PluginData" ]]; then
    for file in "$app_dir"/PluginData/*/*; do
      [[ -f "$file" && $(stat -f %z "$file") -lt 1048576 ]] || continue
      rel="${file#"$app_dir/PluginData/"}"
      mkdir -p "$data_dir/plugin-data/$(dirname "$rel")"
      cp "$file" "$data_dir/plugin-data/$rel"
    done
  fi

  : > "$data_dir/plugins.txt"
  for bundle in "$app_dir"/Plugins/*.bundle; do
    [[ -e "$bundle" ]] || continue
    echo "$(basename "$bundle" .bundle)" >> "$data_dir/plugins.txt"
  done

  security dump-keychain 2>/dev/null \
    | sed -n "s/.*\"svce\"<blob>=\"\\($domain\\.[^\"]*\\)\".*/\\1/p" | sort -u > "$data_dir/keychain-services.txt" || true

  printf 'exported from %s at %s\napp commit %s\n' "$(scutil --get ComputerName 2>/dev/null || hostname)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git -C "$repo_root" rev-parse --short HEAD)" > "$data_dir/source.txt"

  git -C "$sync_repo" add -A
  if git -C "$sync_repo" diff --cached --quiet; then
    log "no settings changes since the last export"
  else
    git -C "$sync_repo" commit -q -m "Settings from $(scutil --get ComputerName 2>/dev/null || hostname)"
    log "committed $(git -C "$sync_repo" rev-parse --short HEAD)"
  fi
  git -C "$sync_repo" push -q -u origin main
  log "exported to $remote"
}

import_settings() {
  ensure_repo
  [[ -f "$data_dir/preferences.plist" ]] || die "$remote has no exported settings yet"
  log "importing settings: $(head -1 "$data_dir/source.txt")"
  quit_app
  mkdir -p "$app_dir"
  backup="$app_dir/settings-sync.replaced/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  defaults export "$domain" "$backup/preferences.plist" 2>/dev/null || true

  # Synced keys overwrite local ones; machine-specific local keys stay.
  python3 -c "$prefs_filter"'
local_path, synced_path, home, out = sys.argv[1:5]
try:
    with open(local_path, "rb") as f:
        merged = plistlib.load(f)
except Exception:
    merged = {}
with open(synced_path, "rb") as f:
    synced = plistlib.load(f)
def rehome(value):
    if isinstance(value, str) and (value == "$HOME" or value.startswith("$HOME/")):
        return home + value[len("$HOME"):]
    return value
merged.update({k: rehome(v) for k, v in synced.items() if not EXCLUDE.search(k)})
with open(out, "wb") as f:
    plistlib.dump(merged, f, fmt=plistlib.FMT_XML)
' "$backup/preferences.plist" "$data_dir/preferences.plist" "$HOME" "$backup/merged.plist"
  defaults import "$domain" "$backup/merged.plist"
  rm "$backup/merged.plist"

  for dump in "$data_dir"/stores/*.sql; do
    [[ -e "$dump" ]] || continue
    store="$(basename "$dump" .sql)"
    for suffix in "" -wal -shm; do
      [[ -e "$app_dir/$store.store$suffix" ]] && mv "$app_dir/$store.store$suffix" "$backup/"
    done
    sqlite3 "$app_dir/$store.store" < "$dump"
  done

  if [[ -d "$data_dir/plugin-data" ]]; then
    rsync -a --backup --backup-dir="$backup/PluginData" "$data_dir/plugin-data/" "$app_dir/PluginData/"
  fi
  log "previous settings kept in $backup"

  missing="$(comm -23 <(sort -u "$data_dir/keychain-services.txt") \
    <(security dump-keychain 2>/dev/null | sed -n "s/.*\"svce\"<blob>=\"\\($domain\\.[^\"]*\\)\".*/\\1/p" | sort -u) || true)"
  if [[ -n "$missing" ]]; then
    log "enter these keys in the app's plugin settings (Keychain is not synced):"
    sed "s/^$domain\\.apikey\\./  /" <<<"$missing"
  fi
}

case "$mode" in
  export) export_settings ;;
  import) import_settings ;;
  *) die "unknown mode: $mode (use export or import)" ;;
esac
