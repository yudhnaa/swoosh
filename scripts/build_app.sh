#!/bin/bash
set -euo pipefail

APP_NAME="${APP_NAME:-Swoosh}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.example.Swoosh}"
CONFIGURATION="${CONFIGURATION:-release}"
CODESIGN_IDENTITY="${SWOOSH_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_APP=false

auto_detect_codesign_identity() {
    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')"

    local count
    count="$(printf '%s\n' "${identities}" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [[ "${count}" == "1" ]]; then
        printf '%s\n' "${identities}"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)
            INSTALL_APP=true
            shift
            ;;
        --identity)
            CODESIGN_IDENTITY="${2:-}"
            shift 2
            ;;
        --bundle-id)
            BUNDLE_IDENTIFIER="${2:-}"
            shift 2
            ;;
        --help|-h)
            cat << HELP
Usage: scripts/build_app.sh [--install] [--identity "Certificate Name"] [--bundle-id "com.example.Swoosh"]

Environment:
  SWOOSH_CODESIGN_IDENTITY  Stable signing identity to preserve macOS permissions across rebuilds.
                            If omitted and exactly one identity exists, it is used automatically.
                            Set to "-" to force ad-hoc signing.
  BUNDLE_IDENTIFIER         Bundle identifier. Defaults to com.example.Swoosh.
  INSTALL_DIR               Install destination for --install. Defaults to /Applications.

Tip:
  Ad-hoc signing (-) changes identity every build, so Accessibility/Input Monitoring permissions
  can reset. Use the same local or Apple Development certificate for every build.
HELP
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 64
            ;;
    esac
done

if [[ -z "${CODESIGN_IDENTITY}" ]]; then
    CODESIGN_IDENTITY="$(auto_detect_codesign_identity)"
fi

APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building ${CONFIGURATION} binary..."
swift build -c "${CONFIGURATION}" --product swoosh
BUILD_DIR="$(swift build -c "${CONFIGURATION}" --show-bin-path)"

echo "Creating app bundle structure..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

echo "Copying binary..."
cp "${BUILD_DIR}/swoosh" "${MACOS_DIR}/${APP_NAME}"

if [ -f "AppIcon.icns" ]; then
    echo "Copying AppIcon..."
    cp "AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

echo "Creating Info.plist..."
cat << PLIST > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_IDENTIFIER}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

if [[ -n "${CODESIGN_IDENTITY}" && "${CODESIGN_IDENTITY}" != "-" ]]; then
    echo "Applying stable code signature: ${CODESIGN_IDENTITY}"
    codesign --force --deep --sign "${CODESIGN_IDENTITY}" "${APP_DIR}"
else
    echo "Applying ad-hoc code signature..."
    echo "Warning: ad-hoc signing can make macOS permissions reset after each rebuild."
    echo "Set SWOOSH_CODESIGN_IDENTITY to a stable certificate name to avoid repeated permission setup."
    codesign --force --deep --sign "-" "${APP_DIR}"
fi

if [[ "${INSTALL_APP}" == true ]]; then
    INSTALL_APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"
    echo "Installing to ${INSTALL_APP_PATH}..."
    ditto "${APP_DIR}" "${INSTALL_APP_PATH}"
fi

echo "Compressing bundle..."
zip -rq "${APP_NAME}.zip" "${APP_DIR}"

echo "Done! App created at ${APP_DIR} and compressed as ${APP_NAME}.zip"
