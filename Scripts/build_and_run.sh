#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="Easy Card"
EXECUTABLE_NAME="EasyCard"
LEGACY_EXECUTABLE_NAME="MarkdownCard"
BUNDLE_ID="com.garden100.MarkdownCard"
APP_BUNDLE="$DIST/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
HELPERS="$CONTENTS/Helpers"
RESOURCES="$CONTENTS/Resources"

# Keep compiler caches inside the project so local builds also work from
# sandboxed development tools without writing to ~/.cache.
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swiftpm-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

build_renderer() {
  if [ ! -d "$ROOT/Renderer/node_modules" ]; then
    npm --prefix "$ROOT/Renderer" install
  fi
  npm --prefix "$ROOT/Renderer" run build
}

build_swift() {
  swift build --package-path "$ROOT" -c release
}

assemble_bundle() {
  local bin_dir
  bin_dir="$(swift build --package-path "$ROOT" -c release --show-bin-path)"

  rm -rf "$APP_BUNDLE" "$DIST/Markdown Card.app"
  mkdir -p "$MACOS" "$HELPERS" "$RESOURCES/Renderer"
  cp "$bin_dir/$EXECUTABLE_NAME" "$MACOS/$EXECUTABLE_NAME"
  cp "$bin_dir/mdcard" "$HELPERS/mdcard"
  cp -R "$ROOT/Resources/Renderer"/. "$RESOURCES/Renderer/"
  xcrun actool "$ROOT/Resources/Assets.xcassets" \
    --compile "$RESOURCES" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --app-icon AppIcon \
    --output-partial-info-plist "$ROOT/.build/AppIconInfo.plist" \
    --warnings \
    --notices >/dev/null
  test -f "$RESOURCES/AppIcon.icns"
  test -f "$RESOURCES/Assets.car"
  chmod +x "$MACOS/$EXECUTABLE_NAME" "$HELPERS/mdcard"

  cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

  codesign --force --deep --sign - "$APP_BUNDLE"
  touch "$APP_BUNDLE"

  local lsregister
  lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [ -x "$lsregister" ]; then
    "$lsregister" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi
}

build_all() {
  build_renderer
  build_swift
  assemble_bundle
  echo "Built $APP_BUNDLE"
}

stop_running_app() {
  if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1 \
    || pgrep -x "$LEGACY_EXECUTABLE_NAME" >/dev/null 2>&1; then
    local control_cli="$HELPERS/mdcard"
    if [ ! -x "$control_cli" ] \
      && [ -x "$DIST/Markdown Card.app/Contents/Helpers/mdcard" ]; then
      control_cli="$DIST/Markdown Card.app/Contents/Helpers/mdcard"
    fi
    if [ ! -x "$control_cli" ]; then
      echo "An Easy Card process is running, but its bundled CLI is unavailable." >&2
      echo "Quit it from Command Center or with mdcard quit, then run this command again." >&2
      exit 1
    fi
    if ! "$control_cli" quit >/dev/null 2>&1; then
      echo "Easy Card is running but did not accept a graceful quit." >&2
      echo "Quit it from Command Center or with mdcard quit, then run this command again." >&2
      exit 1
    fi
    for _ in $(seq 1 80); do
      if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1 \
        && ! pgrep -x "$LEGACY_EXECUTABLE_NAME" >/dev/null 2>&1; then
        break
      fi
      sleep 0.05
    done
    if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1 \
      || pgrep -x "$LEGACY_EXECUTABLE_NAME" >/dev/null 2>&1; then
      echo "Easy Card did not finish its persistence flush within four seconds." >&2
      exit 1
    fi
  fi
}

launch_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  build)
    build_all
    ;;
  run)
    stop_running_app
    build_all
    launch_app
    ;;
  verify)
    stop_running_app
    build_all
    launch_app
    sleep 2
    if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
      if "$HELPERS/mdcard" theme >/dev/null; then
        echo "$EXECUTABLE_NAME is running and IPC is ready."
      else
        echo "$EXECUTABLE_NAME is running but IPC is unavailable." >&2
        exit 1
      fi
    else
      echo "$EXECUTABLE_NAME did not stay running." >&2
      exit 1
    fi
    ;;
  logs)
    stop_running_app
    build_all
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  install-cli)
    build_all
    mkdir -p "$HOME/.local/bin"
    cp "$HELPERS/mdcard" "$HOME/.local/bin/mdcard"
    chmod +x "$HOME/.local/bin/mdcard"
    echo "Installed $HOME/.local/bin/mdcard"
    ;;
  *)
    echo "usage: $0 [build|run|verify|logs|install-cli]" >&2
    exit 2
    ;;
esac
