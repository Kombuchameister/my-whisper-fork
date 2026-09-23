#!/usr/bin/env bash
# Build first-party plugins from this checkout and install them into one
# TypeWhisper app's isolated Plugins directory, replacing whatever binary was
# there (for example a bundle downloaded from the upstream registry).
#
# Usage:
#   scripts/fork/install-plugins.sh --app-support TypeWhisper-Dev-main
#   scripts/fork/install-plugins.sh --app-support TypeWhisper-Dev-main --add GroqPlugin --add OpenAIPlugin
#
# By default every plugin bundle already installed in the target is rebuilt.
# --add installs additional plugins; --only limits the run to named plugins.
# Replaced bundles are moved to <app-support>/Plugins.replaced/<timestamp>/.
# A provenance record is written to <app-support>/fork-plugins.lock.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_support_root="$HOME/Library/Application Support"
derived_root="$repo_root/.build/fork-plugins"
app_support_name=""
declare -a add_plugins=()
declare -a only_plugins=()

log() { printf '[fork-plugins] %s\n' "$*"; }
die() { printf '[fork-plugins] error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-support) app_support_name="$2"; shift 2 ;;
    --add) add_plugins+=("$2"); shift 2 ;;
    --only) only_plugins+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$app_support_name" ]] || die "--app-support <directory name under Application Support> is required"
if [[ "$app_support_name" == "TypeWhisper" ]]; then
  die "the production app (TypeWhisper) is the upstream fallback and is never modified"
fi

target_dir="$app_support_root/$app_support_name"
plugins_dir="$target_dir/Plugins"
[[ -d "$target_dir" ]] || die "no such app support directory: $target_dir"
mkdir -p "$plugins_dir"

# Developer apps are the only ones that use isolated plugin directories;
# the production app in /Applications is ignored here.
if pgrep -fl "/MacOS/TypeWhisper" | grep -v "^[0-9]* /Applications/TypeWhisper.app/" >/dev/null; then
  log "warning: a developer TypeWhisper app is running; restart it to load the rebuilt plugins"
fi

declare -a plugins=()
if [[ ${#only_plugins[@]} -gt 0 ]]; then
  plugins=("${only_plugins[@]}")
else
  for bundle in "$plugins_dir"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    plugins+=("$(basename "$bundle" .bundle)")
  done
  plugins+=("${add_plugins[@]+"${add_plugins[@]}"}")
fi
[[ ${#plugins[@]} -gt 0 ]] || die "nothing to build: no installed plugins and no --add/--only given"

# De-duplicate while keeping order.
declare -a unique=()
for p in "${plugins[@]}"; do
  [[ " ${unique[*]-} " == *" $p "* ]] || unique+=("$p")
done
plugins=("${unique[@]}")

commit="$(git -C "$repo_root" rev-parse HEAD)"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
dirty=""
[[ -z "$(git -C "$repo_root" status --porcelain -- TypeWhisperPluginSDK)" ]] || dirty="+dirty"

log "resolving packages"
xcodebuild -resolvePackageDependencies -project "$repo_root/TypeWhisper.xcodeproj" -scheme TypeWhisper >/dev/null

mkdir -p "$derived_root"
stamp="$(date +%Y%m%d-%H%M%S)"
replaced_dir="$target_dir/Plugins.replaced/$stamp"
lock_file="$target_dir/fork-plugins.lock"
lock_tmp="$(mktemp)"
printf '# Written by scripts/fork/install-plugins.sh on %s\n# source %s %s%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" "$commit" "$dirty" > "$lock_tmp"

for plugin in "${plugins[@]}"; do
  manifest="$repo_root/TypeWhisperPluginSDK/Plugins/$plugin/manifest.json"
  [[ -f "$manifest" ]] || die "no plugin source for $plugin (expected $manifest)"
  version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$manifest")"

  log "building $plugin $version"
  xcodebuild -skipPackagePluginValidation \
    -project "$repo_root/TypeWhisper.xcodeproj" \
    -target "$plugin" \
    -configuration Release \
    SYMROOT="$derived_root/Build/Products" \
    OBJROOT="$derived_root/Build/Intermediates.noindex" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$version" >"$derived_root.$plugin.log" 2>&1 \
    || die "build failed for $plugin; see $derived_root.$plugin.log"

  built="$derived_root/Build/Products/Release/$plugin.bundle"
  [[ -d "$built" ]] || die "build produced no bundle at $built"

  if [[ -e "$plugins_dir/$plugin.bundle" ]]; then
    mkdir -p "$replaced_dir"
    mv "$plugins_dir/$plugin.bundle" "$replaced_dir/"
  fi
  ditto "$built" "$plugins_dir/$plugin.bundle"
  printf '%s %s %s%s\n' "$plugin" "$version" "$commit" "$dirty" >> "$lock_tmp"
done

# Keep provenance lines for plugins this run did not rebuild.
if [[ -f "$lock_file" ]]; then
  grep -v '^#' "$lock_file" | while read -r name rest; do
    [[ " ${plugins[*]} " == *" $name "* ]] || printf '%s %s\n' "$name" "$rest"
  done >> "$lock_tmp"
fi
mv "$lock_tmp" "$lock_file"
log "installed ${#plugins[@]} plugin(s) into $plugins_dir"
if [[ -d "$replaced_dir" ]]; then
  log "previous bundles moved to $replaced_dir"
fi
log "provenance written to $lock_file"
