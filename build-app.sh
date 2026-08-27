#!/bin/sh
# Builds Ivy.app in an ignored, Spotlight-excluded build directory.
# Requires macOS with the Xcode command line tools (xcode-select --install).
# The flow lives in ../leafiy-ui/scripts/macos-app-build-common.sh (ADR-0012);
# this file only declares the app. UNIVERSAL=1 builds one app for both CPUs.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"

APP_SLUG="ivy"
APP_EXECUTABLE_PRODUCT="ivy"
APP_ICON_SOURCE="ivy.png"
MENU_ICON_SOURCE="Sources/Ivy/Resources/Icons/ivy.png"
APP_RESOURCE_PRUNE="Ivy_Ivy.bundle/Ivy.icns Ivy_Ivy.bundle/ivy-app-icon.png Ivy_Ivy.bundle/ivy-menubar-template.png Ivy_Ivy.bundle/ivy-source.webp"
BUILD_COMMON="../leafiy-ui/scripts/macos-app-build-common.sh"
[ -r "$BUILD_COMMON" ] || { echo "error: shared macOS build policy not found: $BUILD_COMMON"; exit 1; }
. "$BUILD_COMMON"
leafiy_build_app_main "$@"
