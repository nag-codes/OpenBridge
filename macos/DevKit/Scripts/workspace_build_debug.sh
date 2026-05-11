#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

while [[ ! -e OpenBridge.xcworkspace ]] && [[ ! -f OpenBridge.xcodeproj ]] && [[ "$(pwd)" != "/" ]]; do
  cd ..
done

if [[ ! -e OpenBridge.xcworkspace ]] && [[ ! -f OpenBridge.xcodeproj ]]; then
  echo "[!] could not locate project root or workspace"
  exit 1
fi

PROJECT_ROOT=$(pwd)
WORKSPACE="OpenBridge.xcworkspace"
SCHEME="OpenBridge"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Debug}"
BUILD_DIR="$PROJECT_ROOT/.build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
XCODEBUILD_LOG="$PROJECT_ROOT/xcodebuild.log"

mkdir -p "$BUILD_DIR"
mkdir -p "$DERIVED_DATA"

function run_xcodebuild() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "$@" 2>&1 | tee "$XCODEBUILD_LOG" | xcbeautify --is-ci --disable-logging --disable-colored-output
  else
    xcodebuild "$@" 2>&1 | tee "$XCODEBUILD_LOG"
  fi
}

function remove_legacy_helper_from_previous_build() {
  local app="$DERIVED_DATA/Build/Products/$BUILD_CONFIGURATION/${SCHEME}.app"
  local helper="$app/Contents/Helpers/OpenBridge Computer Use.app"
  if [[ -d "$helper" ]]; then
    echo "[*] removing legacy OpenBridge Computer Use helper from previous build"
    rm -rf "$helper"
  fi
}

function resign_unsigned_debug_app() {
  local app="$1"
  if [[ "$BUILD_CONFIGURATION" != Unsigned* && "${CODE_SIGNING_ALLOWED:-}" != "NO" ]]; then
    return
  fi

  local entitlements="$PROJECT_ROOT/OpenBridge/Signing/Entitlements.entitlements"
  echo "[*] ad-hoc signing unsigned debug app"
  local codesign_args=(
    --force
    --sign -
    --timestamp=none
  )
  if [[ -f "$entitlements" ]]; then
    codesign_args+=(--entitlements "$entitlements")
  fi
  codesign "${codesign_args[@]}" "$app"
  codesign --verify --strict --verbose=2 "$app"
}

echo "[*] building $SCHEME in $BUILD_CONFIGURATION configuration"
echo "[*] derived data: $DERIVED_DATA"

remove_legacy_helper_from_previous_build

run_xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration "$BUILD_CONFIGURATION" \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -derivedDataPath "$DERIVED_DATA" \
  build

BRIDGE_APP="$DERIVED_DATA/Build/Products/$BUILD_CONFIGURATION/${SCHEME}.app"
resign_unsigned_debug_app "$BRIDGE_APP"

echo "[*] build completed successfully"
echo "[*] app location: $BRIDGE_APP"
