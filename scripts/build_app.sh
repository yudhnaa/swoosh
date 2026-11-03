#!/bin/bash
set -euo pipefail

APP_NAME="${APP_NAME:-Swoosh}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.yudhnaa.Swoosh}"
CONFIGURATION="${CONFIGURATION:-release}"
CODESIGN_IDENTITY="${SWOOSH_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_APP=false
DEVELOPMENT_AD_HOC=false
DRY_RUN=false
STAGING_DIR=""
INSTALL_STAGING_DIR=""
DESIGNATED_REQUIREMENT_PATH="${APP_NAME}.designated-requirement.txt"

usage() {
    cat <<'HELP'
Usage: scripts/build_app.sh [options]

Options:
  --install                    Cleanly replace the app in INSTALL_DIR after verification.
  --identity "Certificate"     Stable signing identity (required for release if auto-detection fails).
  --bundle-id "identifier"     Bundle identifier. Defaults to com.yudhnaa.Swoosh.
  --configuration "name"       Swift build configuration. Defaults to release.
  --development-ad-hoc         Build debug and explicitly opt in to ad-hoc signing.
  --dry-run                    Validate options and print the packaging plan without building.
  --help                       Show this help.

Environment:
  SWOOSH_CODESIGN_IDENTITY  Stable signing identity to preserve macOS permissions across rebuilds.
                            If omitted and exactly one identity exists, it is used automatically.
  BUNDLE_IDENTIFIER         Bundle identifier. Defaults to com.yudhnaa.Swoosh.
  CONFIGURATION             Swift build configuration. Defaults to release.
  INSTALL_DIR               Install destination for --install. Defaults to /Applications.

Release builds require a stable signing identity. Ad-hoc signing is available only through
--development-ad-hoc, which uses the debug configuration and may reset macOS permissions.
HELP
}

fail() {
    echo "Error: $*" >&2
    exit 64
}

require_option_value() {
    local option="$1"
    local value="${2:-}"
    [[ -n "${value}" ]] || fail "${option} requires a value."
}

auto_detect_codesign_identity() {
    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')"

    local count
    count="$(printf '%s\n' "${identities}" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [[ "${count}" == "1" ]]; then
        printf '%s\n' "${identities}"
    fi
}

cleanup() {
    if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
        rm -rf "${STAGING_DIR}"
    fi
    if [[ -n "${INSTALL_STAGING_DIR}" && -d "${INSTALL_STAGING_DIR}" ]]; then
        rm -rf "${INSTALL_STAGING_DIR}"
    fi
}

designated_requirement() {
    local app_path="$1"
    local output
    output="$(codesign -d -r- "${app_path}" 2>&1)" || return 1
    printf '%s\n' "${output}" | sed -n 's/^designated => //p'
}

warn_if_designated_requirement_changes() {
    local previous_app="$1"
    local replacement_app="$2"
    local description="$3"

    [[ -e "${previous_app}" ]] || return 0

    local previous_requirement
    local replacement_requirement
    previous_requirement="$(designated_requirement "${previous_app}" || true)"
    replacement_requirement="$(designated_requirement "${replacement_app}" || true)"

    if [[ -z "${previous_requirement}" || -z "${replacement_requirement}" ]]; then
        echo "Warning: unable to compare the designated requirements for ${description}." >&2
        return 0
    fi

    if [[ "${previous_requirement}" != "${replacement_requirement}" ]]; then
        echo "Warning: the designated requirement changed for ${description}." >&2
        echo "  Previous: ${previous_requirement}" >&2
        echo "  New:      ${replacement_requirement}" >&2
        echo "macOS may treat this as a different app and request permissions again." >&2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)
            INSTALL_APP=true
            shift
            ;;
        --identity)
            require_option_value "$1" "${2:-}"
            CODESIGN_IDENTITY="$2"
            shift 2
            ;;
        --bundle-id)
            require_option_value "$1" "${2:-}"
            BUNDLE_IDENTIFIER="$2"
            shift 2
            ;;
        --configuration)
            require_option_value "$1" "${2:-}"
            CONFIGURATION="$2"
            shift 2
            ;;
        --development-ad-hoc|--development-adhoc)
            DEVELOPMENT_AD_HOC=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

if [[ "${DEVELOPMENT_AD_HOC}" == true ]]; then
    if [[ -n "${CODESIGN_IDENTITY}" && "${CODESIGN_IDENTITY}" != "-" ]]; then
        fail "--development-ad-hoc cannot be combined with a stable signing identity."
    fi
    if [[ "${CONFIGURATION}" == "release" ]]; then
        CONFIGURATION="debug"
    elif [[ "${CONFIGURATION}" != "debug" ]]; then
        fail "--development-ad-hoc requires the debug configuration."
    fi
    CODESIGN_IDENTITY="-"
else
    if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
        fail "ad-hoc signing requires the explicit --development-ad-hoc flag."
    fi
    if [[ -z "${CODESIGN_IDENTITY}" ]]; then
        CODESIGN_IDENTITY="$(auto_detect_codesign_identity)"
    fi
    if [[ -z "${CODESIGN_IDENTITY}" ]]; then
        fail "no unique stable signing identity was found; pass --identity or use --development-ad-hoc."
    fi
fi

[[ "${APP_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "APP_NAME may contain only letters, digits, dots, underscores, and hyphens."
if [[ "${CONFIGURATION}" == "release" && "${BUNDLE_IDENTIFIER}" != "com.yudhnaa.Swoosh" ]]; then
    fail "release builds require the production bundle identifier com.yudhnaa.Swoosh."
fi

APP_DIR="${APP_NAME}.app"
ZIP_PATH="${APP_NAME}.zip"

if [[ "${DRY_RUN}" == true ]]; then
    echo "Packaging plan:"
    echo "  Configuration: ${CONFIGURATION}"
    echo "  Bundle ID:     ${BUNDLE_IDENTIFIER}"
    echo "  Signing:       ${CODESIGN_IDENTITY}"
    echo "  Output:        ${APP_DIR} and ${ZIP_PATH}"
    if [[ "${INSTALL_APP}" == true ]]; then
        echo "  Install:       ${INSTALL_DIR}/${APP_NAME}.app (clean replacement)"
    fi
    exit 0
fi

trap cleanup EXIT

echo "Building ${CONFIGURATION} binary..."
swift build -c "${CONFIGURATION}" --product swoosh
BUILD_DIR="$(swift build -c "${CONFIGURATION}" --show-bin-path)"
BUILD_BINARY="${BUILD_DIR}/swoosh"
if [[ "${CONFIGURATION}" == "release" ]]; then
    BINARY_ARCHITECTURES="$(lipo -archs "${BUILD_BINARY}")"
    [[ " ${BINARY_ARCHITECTURES} " == *" arm64 "* ]] || fail "release binary does not contain the required arm64 architecture."
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.build.XXXXXX")"
STAGED_APP_DIR="${STAGING_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${STAGED_APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Constructing staged app bundle..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BUILD_BINARY}" "${MACOS_DIR}/${APP_NAME}"

if [[ -f "AppIcon.icns" ]]; then
    cp "AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

cat <<PLIST > "${CONTENTS_DIR}/Info.plist"
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

if [[ "${DEVELOPMENT_AD_HOC}" == true ]]; then
    echo "Applying explicit development ad-hoc signature..."
    echo "Warning: ad-hoc signing can make macOS permissions reset after each rebuild." >&2
else
    echo "Applying stable code signature: ${CODESIGN_IDENTITY}"
fi
codesign --force --deep --sign "${CODESIGN_IDENTITY}" "${STAGED_APP_DIR}"

echo "Verifying staged signature..."
codesign --verify --deep --strict --verbose=2 "${STAGED_APP_DIR}"
warn_if_designated_requirement_changes "${APP_DIR}" "${STAGED_APP_DIR}" "the local app bundle"

echo "Replacing local app bundle..."
LOCAL_BACKUP_APP="${STAGING_DIR}/${APP_NAME}.previous.app"
if [[ -L "${APP_DIR}" ]]; then
    fail "refusing to replace a symbolic-link app bundle: ${APP_DIR}"
fi
if [[ -e "${APP_DIR}" ]]; then
    mv "${APP_DIR}" "${LOCAL_BACKUP_APP}"
fi
if ! ditto "${STAGED_APP_DIR}" "${APP_DIR}" || ! codesign --verify --deep --strict --verbose=2 "${APP_DIR}"; then
    rm -rf "${APP_DIR}"
    if [[ -e "${LOCAL_BACKUP_APP}" ]]; then
        mv "${LOCAL_BACKUP_APP}" "${APP_DIR}"
    fi
    fail "local app replacement failed; the previous bundle was restored."
fi
rm -rf "${LOCAL_BACKUP_APP}"

if [[ "${INSTALL_APP}" == true ]]; then
    INSTALL_APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"
    INSTALL_STAGING_DIR="$(mktemp -d "${INSTALL_DIR}/.${APP_NAME}.install.XXXXXX")"
    INSTALL_STAGED_APP="${INSTALL_STAGING_DIR}/${APP_NAME}.app"

    echo "Staging clean installation for ${INSTALL_APP_PATH}..."
    ditto "${APP_DIR}" "${INSTALL_STAGED_APP}"
    codesign --verify --deep --strict --verbose=2 "${INSTALL_STAGED_APP}"
    warn_if_designated_requirement_changes "${INSTALL_APP_PATH}" "${INSTALL_STAGED_APP}" "the installed app"

    echo "Replacing installed app..."
    INSTALL_BACKUP_APP="${INSTALL_STAGING_DIR}/${APP_NAME}.previous.app"
    if [[ -L "${INSTALL_APP_PATH}" ]]; then
        fail "refusing to replace a symbolic-link installed bundle: ${INSTALL_APP_PATH}"
    fi
    if [[ -e "${INSTALL_APP_PATH}" ]]; then
        mv "${INSTALL_APP_PATH}" "${INSTALL_BACKUP_APP}"
    fi
    if ! mv "${INSTALL_STAGED_APP}" "${INSTALL_APP_PATH}" || ! codesign --verify --deep --strict --verbose=2 "${INSTALL_APP_PATH}"; then
        rm -rf "${INSTALL_APP_PATH}"
        if [[ -e "${INSTALL_BACKUP_APP}" ]]; then
            mv "${INSTALL_BACKUP_APP}" "${INSTALL_APP_PATH}"
        fi
        fail "installed app replacement failed; the previous bundle was restored."
    fi
    rm -rf "${INSTALL_BACKUP_APP}"
fi

designated_requirement "${APP_DIR}" > "${DESIGNATED_REQUIREMENT_PATH}"
[[ -s "${DESIGNATED_REQUIREMENT_PATH}" ]] || fail "could not record the app's designated requirement."

echo "Compressing verified bundle..."
rm -f "${ZIP_PATH}"
zip -rq "${ZIP_PATH}" "${APP_DIR}"

echo "Done! App created at ${APP_DIR} and compressed as ${ZIP_PATH}"
