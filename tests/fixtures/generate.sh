#!/bin/bash
#
# Regenerate the test fixture APKs. Not run by the test suite: the outputs are
# committed so that the tests need no Android SDK.
#
# Requires ANDROID_BUILD_TOOLS (containing aapt2, zipalign, apksigner) and
# ANDROID_JAR (a platform android.jar).

set -euo pipefail

BT="${ANDROID_BUILD_TOOLS:?set ANDROID_BUILD_TOOLS to an Android build-tools directory}"
AJ="${ANDROID_JAR:?set ANDROID_JAR to a platform android.jar}"
OUT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

cd "$WORK"
mkdir -p res/values res/drawable-hdpi res/drawable-xhdpi
cat > res/values/strings.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources><string name="app_name">Fixture App</string></resources>
XML
python3 -c "
import base64
png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
open('res/drawable-hdpi/ic.png','wb').write(png)
open('res/drawable-xhdpi/ic.png','wb').write(png)
open('$OUT/icon.png','wb').write(png)
"
"$BT/aapt2" compile --dir res -o compiled.zip

keytool -genkeypair -keystore a.jks -storepass fixture -keyalg RSA -keysize 2048 \
    -validity 10000 -alias a -dname "CN=Fixture Signer A, O=MyAppStore Tests" >/dev/null 2>&1
keytool -genkeypair -keystore b.jks -storepass fixture -keyalg RSA -keysize 2048 \
    -validity 10000 -alias b -dname "CN=Fixture Signer B, O=MyAppStore Tests" >/dev/null 2>&1

build() { # versionCode versionName keystore alias outdir with_split
    mkdir -p "$5"
    cat > m.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.fixture" android:versionCode="$1" android:versionName="$2">
    <uses-sdk android:minSdkVersion="31" android:targetSdkVersion="35" />
    <application android:label="@string/app_name" android:hasCode="false" />
</manifest>
XML
    local split_args=()
    [ "$6" = yes ] && split_args=(--split s.apk:hdpi)
    "$BT/aapt2" link -o u.apk -I "$AJ" --manifest m.xml -R compiled.zip --auto-add-overlay \
        --min-sdk-version 31 --target-sdk-version 35 "${split_args[@]}"
    "$BT/zipalign" -p -f 4 u.apk ua.apk
    "$BT/apksigner" sign --ks "$3" --ks-pass pass:fixture --ks-key-alias "$4" \
        --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true \
        --v4-signing-enabled true --min-sdk-version 31 --out "$5/base.apk" ua.apk
    if [ "$6" = yes ]; then
        "$BT/zipalign" -p -f 4 s.apk sa.apk
        "$BT/apksigner" sign --ks "$3" --ks-pass pass:fixture --ks-key-alias "$4" \
            --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true \
            --v4-signing-enabled true --min-sdk-version 31 --out "$5/split_config.hdpi.apk" sa.apk
    fi
    rm -f u.apk ua.apk s.apk sa.apk m.xml
}

build 42 "1.2.3" a.jks a "$OUT/v42" yes
build 43 "1.2.4" a.jks a "$OUT/v43" no
build 44 "1.2.5" b.jks b "$OUT/other-signer" no

echo "regenerated fixtures in $OUT"
