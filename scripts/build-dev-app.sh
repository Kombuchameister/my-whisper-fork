#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${TYPEWHISPER_DERIVED_DATA_PATH:-/tmp/typewhisper-derived-dev}"
DESTINATION_APP="${TYPEWHISPER_DEV_APP_PATH:-${HOME}/Applications/TypeWhisper Dev.app}"
BUILT_APP="${DERIVED_DATA_PATH}/Build/Products/Debug/TypeWhisper.app"

mkdir -p "$(dirname "${DESTINATION_APP}")"

/usr/bin/xattr -cr "${ROOT_DIR}/TypeWhisper/Resources" \
  "${ROOT_DIR}/TypeWhisperPluginSDK/Plugins/SpeechAnalyzerPlugin" 2>/dev/null || true
/bin/rm -rf "${DERIVED_DATA_PATH}/Build/Products/Debug/SpeechAnalyzerPlugin.bundle"

/usr/bin/xcodebuild build \
  -project "${ROOT_DIR}/TypeWhisper.xcodeproj" \
  -scheme TypeWhisper \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -parallelizeTargets \
  -jobs "${XCODE_BUILD_JOBS:-10}"

if [[ ! -d "${BUILT_APP}" ]]; then
  echo "Built app was not found at: ${BUILT_APP}" >&2
  exit 1
fi

/usr/bin/pkill -x TypeWhisper 2>/dev/null || true
/bin/rm -rf "${DESTINATION_APP}"
/usr/bin/ditto "${BUILT_APP}" "${DESTINATION_APP}"

echo "${DESTINATION_APP}"
