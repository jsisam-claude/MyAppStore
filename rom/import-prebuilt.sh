#!/bin/bash
#
# Validate a built client APK and stage it for the OS image.
#
#   ./rom/import-prebuilt.sh path/to/app-release.apk
#
# Checks that the APK is the right package, is signed with a real release key
# rather than a debug key, and prints the signing certificate digest so it can
# be recorded and compared on the next release.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
EXPECTED_PACKAGE="app.myappstore"
DEST="$ROOT/rom/prebuilt/MyAppStore.apk"

apk="${1:-}"
if [ -z "$apk" ] || [ ! -f "$apk" ]; then
    echo "usage: rom/import-prebuilt.sh <app-release.apk>" >&2
    exit 1
fi

facts="$(python3 "$ROOT/scripts/lib/apkinfo.py" --shell "$apk")"
eval "$facts"

if [ "$APK_PACKAGE" != "$EXPECTED_PACKAGE" ]; then
    echo "error: $apk is $APK_PACKAGE, expected $EXPECTED_PACKAGE." >&2
    echo "       The privapp allowlist names $EXPECTED_PACKAGE; a mismatch means" >&2
    echo "       INSTALL_PACKAGES is not granted and the device will not boot." >&2
    exit 1
fi

if [ -z "$APK_SIGNATURE_SCHEME" ]; then
    echo "error: $apk has no v2 or newer signature." >&2
    exit 1
fi

if command -v apksigner >/dev/null 2>&1; then
    apksigner verify --min-sdk-version "${APK_MIN_SDK:-31}" -- "$apk" >/dev/null ||
        { echo "error: apksigner rejected $apk" >&2; exit 1; }
    if apksigner verify --print-certs "$apk" 2>/dev/null | grep -q 'CN=Android Debug'; then
        echo "error: $apk is signed with the Android debug key. Build a release" >&2
        echo "       APK with your own keystore; the signing key can never change." >&2
        exit 1
    fi
    echo "apksigner: signature verified"
else
    echo "warning: apksigner is not installed; the signature was read but not verified" >&2
fi

mkdir -p "$(dirname "$DEST")"
cp -- "$apk" "$DEST.tmp"
chmod 644 "$DEST.tmp"
mv -f "$DEST.tmp" "$DEST"

cat <<EOF

staged $DEST
  package      $APK_PACKAGE
  versionCode  $APK_VERSION_CODE
  versionName  ${APK_VERSION_NAME:-$APK_VERSION_CODE}
  signature    $APK_SIGNATURE_SCHEME
  signer       $APK_CERT_DIGESTS

Record that signer digest. Every later release must use the same key, and
appstore-add --expect-cert will check it when you publish the store to its own
repository.
EOF
