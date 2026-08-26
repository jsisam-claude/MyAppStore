# Bundling the store into the OS image

This directory ships MyAppStore as a prebuilt privileged app in a GrapheneOS
(or AOSP) build.

Privileged matters: with `INSTALL_PACKAGES` the store installs and updates
packages itself, so updates apply without a per-app confirmation prompt. Without
it the app still works, but every install goes through the "install unknown
apps" flow.

## One-time setup

**1. Create a release keystore for the client and never lose it.**

```sh
keytool -genkeypair -v -keystore myappstore-release.jks -alias myappstore \
    -keyalg RSA -keysize 4096 -validity 10000
```

The store updates itself over the network, and Android refuses an update signed
by a different key than the installed one. Losing this key means every device
has to be reflashed to move off the old build.

**2. Point the client at your repository.**

On the repository host:

```sh
appstore-client-config > client/repo.properties
```

**3. Tell Gradle about the keystore** by writing `client/keystore.properties`:

```properties
storeFile=myappstore-release.jks
storePassword=...
keyAlias=myappstore
keyPassword=...
```

Both files are gitignored, and both are credentials.

## Each release

```sh
cd client && ./gradlew assembleRelease
cd .. && ./rom/import-prebuilt.sh client/app/build/outputs/apk/release/app-release.apk
```

`import-prebuilt.sh` refuses an APK with the wrong package name or a debug
signing key, verifies the signature when `apksigner` is available, and prints the
signing certificate digest. Record that digest: it must never change.

Then put this directory somewhere in the build tree, for example
`vendor/myorg/myappstore/`, and add to your device or product makefile:

```make
$(call inherit-product, vendor/myorg/myappstore/rom/myappstore.mk)
```

Soong picks up `Android.bp` on its own. The build installs:

```
/product/priv-app/MyAppStore/MyAppStore.apk
/product/etc/permissions/privapp-permissions-myappstore.xml
```

## If the device does not boot

Almost always the privileged permission allowlist. GrapheneOS builds with
`ro.control_privapp_permissions=enforce`, so a privileged app requesting a
`signature|privileged` permission that is not allowlisted is a fatal error
rather than a denied permission.

`logcat` names the package and permission. Check that:

- `applicationId` in `client/app/build.gradle.kts` matches the `package`
  attribute in `privapp-permissions-myappstore.xml`. `import-prebuilt.sh`
  checks this for you.
- The allowlist landed on the same partition as the APK. Both are
  `product_specific: true` here; changing one means changing the other.
- Any permission you add to the app's manifest that is `signature|privileged`
  gets an `<allow-permission>` entry. Today `INSTALL_PACKAGES` is the only one.

## Letting the store update itself

The bundled APK is a floor, not a ceiling: publish the store to its own
repository and it will update itself from `/data` like any other app.

```sh
appstore-add --self-updating \
    --label "MyAppStore" \
    --expect-cert <the digest import-prebuilt.sh printed> \
    client/app/build/outputs/apk/release/app-release.apk
appstore-publish
```

`--self-updating` sets `optOutOfBulkUpdates`, which keeps the store out of
"Update all" and the auto-update job. A store that tries to update itself in the
middle of a bulk update kills the process doing the updating.

`--expect-cert` fails the add if the APK is not signed with the key the ROM
shipped, which is the mistake that would otherwise ship an update no device can
install.

## Running alongside, or instead of, GrapheneOS Apps

The fork uses `applicationId = app.myappstore`, so it installs next to
GrapheneOS Apps and both work. That is the recommended arrangement: GrapheneOS
Apps keeps delivering Vanadium, GmsCompat and the rest, and yours delivers your
apps.

To replace GrapheneOS Apps instead, set `applicationId` to `app.grapheneos.apps`,
update the package name in `privapp-permissions-myappstore.xml`, and add
`overrides: ["Apps"]` to the `android_app_import` block. Be deliberate about it:
your repository then has to carry everything GrapheneOS ships, and the OS
components delivered through their store stop being updated.
