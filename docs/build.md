# Build guide

End to end, from nothing to a device installing apps from your own repository.
Every other document here is reference; this is the one that runs start to
finish.

There are three machines in play, and they can all be the same machine, though
[security.md](security.md#where-the-signing-key-should-live) argues against it:

| | Does | Needs |
|---|---|---|
| **Repository host** | Serves the repository over nginx | bash, openssl, python3, gzip, nginx |
| **Publisher** | Holds the signing key, adds apps | the same, plus Android build-tools *(optional but recommended)* |
| **Build machine** | Builds the client and the OS image | JDK 17+, Android SDK |

Android build-tools are optional on the publisher. With them, `apksigner`
verifies APK signatures before you publish and `aapt2` reads app names so you do
not have to pass `--label`. Without them, both still work, with a warning and a
bit more typing.

---

## Part 1 — The repository

### 1. Install the scripts

Clone the repository and put the commands on `PATH`. They resolve their own
library directory, so symlinks are fine:

```sh
git clone <this repo> /opt/myappstore
sudo ln -s /opt/myappstore/scripts/appstore-* /usr/local/bin/
```

### 2. Create the repository

```sh
sudo appstore-init --url https://apps.example.com
```

The URL is what devices will fetch from; it must be `https://`. This creates
`/var/lib/appstore` (state and keys) and `/var/www/appstore` (what nginx
serves), generates the Ed25519 signing key, and prints the public key and the
first access key.

It prompts for a passphrase for the signing key. Pass `--no-passphrase` if
publishing has to run unattended, and read
[security.md](security.md#where-the-signing-key-should-live) about where that
key should live.

**Back up now, before anything else — and back up both trees.** The public key
gets compiled into every client, so losing the private half means no device can
be given another update until it is reflashed. But keys alone do not restore a
repository; see [Backup, restore and migration](#backup-restore-and-migration)
below for what else has to be saved and why.

### 3. Get a certificate

```sh
sudo certbot certonly --nginx -d apps.example.com
```

The generated site config expects `/etc/letsencrypt/live/<domain>/`. Use
`--cert-dir` in the next step if yours lives elsewhere.

### 4. Configure nginx

```sh
sudo appstore-nginx --install /etc/nginx/sites-available/appstore
sudo ln -s /etc/nginx/sites-available/appstore /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

The config serves two path patterns read-only, refuses everything else, and
rejects any request without the access key. If the host has no IPv6, delete the
`listen [::]` lines.

### 5. Add your first app

```sh
sudo appstore-add --label "Example" --description "What it does." \
    --icon example.png example.apk
sudo appstore-publish
```

Split APKs go in the same command as the base APK:

```sh
sudo appstore-add --label "Example" \
    base.apk split_config.arm64_v8a.apk split_config.en.apk
```

Nothing reaches devices until `appstore-publish` runs. It rebuilds the index,
signs it, verifies its own output, and only then replaces the live one.

### 6. Check it

```sh
sudo appstore-verify --remote
```

This re-verifies the signature with openssl, decompresses and re-hashes every
artifact against the signed index, confirms the bytes served over HTTPS match
the ones on disk, and confirms a request with no access key is refused.

---

## Part 2 — The client

### 7. Create a release keystore

```sh
keytool -genkeypair -v -keystore myappstore-release.jks -alias myappstore \
    -keyalg RSA -keysize 4096 -validity 10000
```

**This key can never change.** The store updates itself over the network, and
Android refuses an update signed by a different key than the installed one.
Losing it means reflashing every device to move off the old build.

### 8. Point the client at your repository

On the repository host:

```sh
sudo appstore-client-config
```

Copy the output to `client/repo.properties` on the build machine. It carries the
repository URL, the signing public key, and an access key — all three get
compiled into the APK. The file is gitignored because that access key is a
shared credential.

Then `client/keystore.properties`:

```properties
storeFile=myappstore-release.jks
storePassword=...
keyAlias=myappstore
keyPassword=...
```

Also gitignored, also a credential.

### 9. Build

```sh
cd client && ./gradlew assembleRelease
```

Output lands at `client/app/build/outputs/apk/release/app-release.apk`.

The build fails rather than falling back to a placeholder repository, so a
missing or malformed `repo.properties` is a build error and not a client that
silently points nowhere.

---

## Part 3 — The OS image

Skip this if you are installing the APK by hand. Bundling it makes the store a
privileged system app, which is what lets it install and update packages without
a confirmation prompt for every one.

### 10. Stage the prebuilt

```sh
./rom/import-prebuilt.sh client/app/build/outputs/apk/release/app-release.apk
```

This refuses an APK with the wrong package name or a debug signing key, verifies
the signature where `apksigner` is available, and prints the signing certificate
digest. **Record that digest** — every later release must match it.

### 11. Wire it into the product

Put the repository somewhere in the build tree, for example
`vendor/myorg/myappstore/`, then add to your device or product makefile:

```make
$(call inherit-product, vendor/myorg/myappstore/rom/myappstore.mk)
```

Soong picks up `rom/Android.bp` on its own. The build installs:

```
/product/priv-app/MyAppStore/MyAppStore.apk
/product/etc/permissions/privapp-permissions-myappstore.xml
```

Build and flash as usual. [rom/README.md](../rom/README.md) covers what to do if
the device does not boot — it is almost always the privileged permission
allowlist.

### 12. Let the store update itself

The bundled APK is a floor, not a ceiling. Publish the store to its own
repository and it updates from `/data` like any other app:

```sh
sudo appstore-add --self-updating --label "MyAppStore" \
    --expect-cert <the digest from step 10> \
    app-release.apk
sudo appstore-publish
```

`--self-updating` keeps it out of "Update all" and the auto-update job; a store
that updates itself mid-bulk-update kills the process doing the updating.
`--expect-cert` fails the add if the APK is not signed with the key the ROM
shipped.

---

## Part 4 — Ongoing

### Publish a new version of an app

```sh
sudo appstore-add --release-notes "Fixes the thing." example-1.3.apk
sudo appstore-publish
```

The versionCode comes from the APK, so a higher one is a new version. Name,
description and icon carry over. See
[Updating an app](../README.md#updating-an-app) for retiring old versions.

### Ship a new client build

Bump `versionCode` in `client/app/build.gradle.kts`, rebuild, re-run
`rom/import-prebuilt.sh`, and publish it to the repository as in step 12.
Devices take it as an ordinary update; only a change to the repository URL,
public key or access key requires a new OS image.

### Rotate the access key

Several keys are valid at once, which is what makes this possible without
locking devices out:

```sh
sudo appstore-key add --label 2026-q3
sudo appstore-key sync
sudo nginx -t && sudo systemctl reload nginx
# ship a client build carrying the new key, wait for devices to take it
sudo appstore-key revoke 2026-q1
sudo appstore-key sync && sudo nginx -t && sudo systemctl reload nginx
```

### Rotate the signing key

Rarer and more disruptive. See
[security.md](security.md#replacing-the-signing-key).

---

## Backup, restore and migration

### What has to be saved

Two directories, and both are required:

| | Holds | Character |
|---|---|---|
| `$APPSTORE_HOME` (`/var/lib/appstore`) | config, signing key, access keys, and the `apps/` fragments that are the source of truth | small, secret |
| `$APPSTORE_WWW` (`/var/www/appstore`) | the `.apk.gz` artifacts and icons | large, public |

**Keys alone restore nothing.** The fragments record each APK's digest and
sizes, never its content, so the `.gz` files in the web root are the only copy
of the APK bytes anywhere in the system. And the fragments themselves cannot be
reconstructed from a published index — descriptions, release notes and channels
live only there.

The failure mode is quiet, which is what makes it worth stating: restoring keys
and the web root but *not* `apps/` leaves an empty `apps/` directory, and
`appstore-publish` will happily sign and install an index containing zero
packages. `appstore-verify` passes, because an empty index is internally
consistent. Every device then sees an empty store.

```sh
sudo tar czf appstore-state.tar.gz -C /var/lib appstore
sudo tar czf appstore-www.tar.gz   -C /var/www appstore
```

Take them together. A web root newer than the state, or the reverse, publishes
an index that does not match the artifacts beside it.

### Restore drill

Worth doing once before you need it, on a scratch host:

```sh
export APPSTORE_HOME=/tmp/drill/state
sudo tar xzf appstore-state.tar.gz -C /tmp/drill --strip-components=1
sudo tar xzf appstore-www.tar.gz   -C /tmp/drill

sudo appstore-list                  # the packages you expect, not zero
sudo appstore-publish --dry-run     # every referenced artifact is present
sudo appstore-verify                # signature and every digest re-checked
```

`appstore-verify` is the drill's real assertion: it re-verifies the Ed25519
signature and decompresses and re-hashes every artifact, which is exactly what a
device does. If it passes, the backup is restorable.

Do **not** run `appstore-init` on a restored tree. It refuses when key material
is present precisely because that is what a restore looks like, but the reflex
is the dangerous one — a new key replaces the trust anchor compiled into every
installed client.

### Moving to a new host

```sh
# on the new host
sudo tar xzf appstore-state.tar.gz -C /var/lib
sudo tar xzf appstore-www.tar.gz   -C /var/www
sudo appstore-nginx --install /etc/nginx/sites-available/appstore
sudo ln -s /etc/nginx/sites-available/appstore /etc/nginx/sites-enabled/
sudo appstore-key sync
sudo nginx -t && sudo systemctl reload nginx
sudo appstore-verify --remote
```

Nothing about the repository is host-specific except the nginx config and the
TLS certificate, so the client needs no rebuild — the URL, public key and access
key are unchanged. Point DNS at the new host once `--remote` passes.

---

## When something is wrong

| Symptom | Cause |
|---|---|
| `nginx: could not build map_hash` | Another config already sets `map_hash_bucket_size`. Remove whichever copy is redundant. |
| `nginx: unknown directive "http2"` | nginx older than 1.25.1. `appstore-nginx` detects this, so regenerate the config on the host that runs nginx. |
| Devices get 401 | The client's access key is not in the map. Compare `appstore-client-config` against `appstore-key list`, and check nginx was reloaded. |
| `appstore-add` refuses: signer mismatch | The APK is signed by a different key than the published version. Devices could not install it. Only `--allow-signer-change` if the key really was rotated. |
| `appstore-add` refuses: already exists | Re-uploading the same versionCode. `--replace` if that is intended. |
| `could not determine a display name` | First version of a package with no `aapt2` installed. Pass `--label`. |
| Device does not boot after flashing | The privapp allowlist. See [rom/README.md](../rom/README.md#if-the-device-does-not-boot). |
| `appstore-publish` warns about a downgrade | The host clock went backwards. It compensates, but fix the clock. |

`appstore-verify` is the first thing to run whenever the repository looks wrong;
it checks the whole chain the way a device would.
