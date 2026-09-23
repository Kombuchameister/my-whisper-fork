#!/usr/bin/env bash
# Snapshot the configuration of every local TypeWhisper app (production and
# developer builds) into a separate, local-only git repository, so settings
# that live outside this checkout are versioned too.
#
# Usage:
#   scripts/fork/snapshot-app-state.sh [--state-repo ~/TypeWhisper-state] [--message "why"]
#
# Per app it records, as diffable text:
#   preferences.plist     the complete preferences domain (XML)
#   stores/<name>.sql     SQL dumps of workflows, profiles, prompt-actions, snippets, dictionary
#   CommandMode/          Command Mode conversations
#   plugins.txt           installed plugin bundles: version, signer, source (fork build or upstream download)
#   fork-plugins.lock     provenance written by install-plugins.sh, when present
#   keychain-services.txt Keychain service NAMES only, never secret values
# It never copies Keychain secrets, dictation history, usage statistics, audio, or model data.
set -euo pipefail

state_repo="$HOME/TypeWhisper-state"
message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-repo) state_repo="$2"; shift 2 ;;
    --message) message="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

app_support_root="$HOME/Library/Application Support"
config_stores=(workflows profiles prompt-actions snippets dictionary)

if [[ ! -d "$state_repo/.git" ]]; then
  mkdir -p "$state_repo"
  git -C "$state_repo" init -q -b main
  cat > "$state_repo/README.md" <<'EOF'
# TypeWhisper local state

Local-only snapshots of TypeWhisper app configuration, written by
`scripts/fork/snapshot-app-state.sh` in the my-whisper-fork checkout.
Contains personal configuration: do not push this repository anywhere public.
Keychain secrets, history, usage statistics, audio, and models are never included.
EOF
fi

# Map each Application Support directory to its preferences domain.
domain_for() {
  case "$1" in
    TypeWhisper) echo "com.typewhisper.mac" ;;
    TypeWhisper-Dev) echo "com.typewhisper.mac.dev" ;;
    TypeWhisper-Dev-*)
      local slug="${1#TypeWhisper-Dev-}"
      echo "com.typewhisper.mac.dev.$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')" ;;
  esac
}

keychain_services="$(security dump-keychain 2>/dev/null \
  | sed -n 's/.*"svce"<blob>="\(com\.typewhisper[^"]*\)".*/\1/p' | sort -u || true)"

for dir in "$app_support_root"/TypeWhisper "$app_support_root"/TypeWhisper-Dev*; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  [[ "$name" == *.before-* ]] && continue
  out="$state_repo/apps/$name"
  rm -rf "$out"
  mkdir -p "$out/stores"

  domain="$(domain_for "$name")"
  if [[ -n "$domain" ]] && defaults export "$domain" - >/dev/null 2>&1; then
    defaults export "$domain" - | plutil -convert xml1 -o "$out/preferences.plist" -
    echo "$domain" > "$out/preferences-domain.txt"
  fi

  for store in "${config_stores[@]}"; do
    db="$dir/$store.store"
    [[ -f "$db" ]] || continue
    sqlite3 -readonly "$db" .dump > "$out/stores/$store.sql"
  done

  if [[ -d "$dir/CommandMode" ]]; then
    rsync -a --exclude .DS_Store --exclude Trash "$dir/CommandMode/" "$out/CommandMode/"
  fi

  : > "$out/plugins.txt"
  for bundle in "$dir"/Plugins/*.bundle; do
    [[ -e "$bundle" ]] || continue
    manifest="$bundle/Contents/Resources/manifest.json"
    version="?"
    [[ -f "$manifest" ]] && version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version","?"))' "$manifest")"
    team="$(codesign -dv "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    case "$team" in
      2D8ALY3LCL) origin="upstream-download" ;;
      ""|"not set") origin="local-build" ;;
      *) origin="team-$team" ;;
    esac
    printf '%s %s %s\n' "$(basename "$bundle" .bundle)" "$version" "$origin" >> "$out/plugins.txt"
  done
  [[ -f "$dir/fork-plugins.lock" ]] && cp "$dir/fork-plugins.lock" "$out/fork-plugins.lock"

  prefix="${domain}."
  [[ "$name" == "TypeWhisper" ]] && prefix="com.typewhisper.mac.apikey."
  grep -F "$prefix" <<<"$keychain_services" > "$out/keychain-services.txt" || true
done

git -C "$state_repo" add -A
if git -C "$state_repo" diff --cached --quiet; then
  echo "[snapshot] no configuration changes"
else
  git -C "$state_repo" commit -q -m "${message:-Snapshot $(date +%Y-%m-%dT%H:%M:%S)}"
  echo "[snapshot] committed $(git -C "$state_repo" rev-parse --short HEAD) in $state_repo"
fi
