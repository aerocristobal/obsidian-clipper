#!/usr/bin/env bash
set -euo pipefail

# Auth: requires the App Store Connect API .p8 in ~/.appstoreconnect/private_keys/.
# File MUST be named with the type-correct prefix or altool sends the wrong JWT:
#   - Team key      -> AuthKey_<KEYID>.p8   (no extra JWT claim)
#   - Individual key -> ApiKey_<KEYID>.p8   (altool auto-adds sub:user)
# Apple's downloaded filename already encodes this; do not rename it.

: "${ASC_API_KEY_ID:?set via op run / 1Password environment}"
: "${ASC_API_ISSUER_ID:?set via op run / 1Password environment}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PROJECT="ObsidianClipper.xcodeproj"
SCHEME="ObsidianClipper"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/ObsidianClipper.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
EXPORT_OPTIONS="scripts/exportOptions.plist"

mkdir -p "${BUILD_DIR}"

echo "==> Archiving (Release, generic iOS device)"
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    clean archive

echo "==> Exporting .ipa"
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -allowProvisioningUpdates

IPA="$(find "${EXPORT_PATH}" -maxdepth 1 -name '*.ipa' -print -quit)"
if [[ -z "${IPA}" ]]; then
    echo "ERROR: no .ipa produced under ${EXPORT_PATH}" >&2
    exit 1
fi

echo "==> Validating ${IPA}"
xcrun altool --validate-app \
    --type ios \
    --file "${IPA}" \
    --apiKey "${ASC_API_KEY_ID}" \
    --apiIssuer "${ASC_API_ISSUER_ID}"

echo "==> Uploading ${IPA}"
xcrun altool --upload-app \
    --type ios \
    --file "${IPA}" \
    --apiKey "${ASC_API_KEY_ID}" \
    --apiIssuer "${ASC_API_ISSUER_ID}"

echo "==> Done. Watch for the 'processing complete' email, then check App Store Connect -> TestFlight."
