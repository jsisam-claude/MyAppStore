# MyAppStore

A fork of the [GrapheneOS App Store](https://github.com/GrapheneOS/Apps) that
serves your own apps from your own nginx, plus the scripts to run that
repository.

The repository is a directory of static files. There is no application server,
no database, and no moving parts on the host beyond nginx serving files and a
handful of shell scripts that write them. Integrity does not come from the
server: the index is signed with an Ed25519 key that never has to touch the web
host, and every APK is committed to by a SHA-256 digest inside that signed
index.

```
                    appstore-add          appstore-publish
   your APKs  ────────────────────►  repo  ───────────────►  signed index
                                      │                            │
                                      └────────► nginx ◄───────────┘
                                                   │  https + access key
                                                   ▼
                                            MyAppStore on device
```

## What is here

| | |
|---|---|
| [`docs/build.md`](docs/build.md) | **Start here.** The full build, end to end: repository, nginx, client, OS image. |
| `client/` | The forked Android client. See [`client/UPSTREAM.md`](client/UPSTREAM.md) for exactly what was changed and how to sync upstream. |
| `scripts/` | `appstore-*`, the repository management commands. |
| `rom/` | Bundling the client into a GrapheneOS build as a prebuilt privileged app. See [`rom/README.md`](rom/README.md). |
| `docs/` | [Security model](docs/security.md), [metadata format](docs/metadata-format.md), [accounts, MDM and SSO](docs/accounts-and-sso.md). |
| `tests/` | End-to-end tests against real signed APK fixtures. |

## Requirements

**Repository host:** bash, openssl, python3, gzip, coreutils, nginx, and
Android build-tools. `apksigner` is required: the signing certificate digests
recorded for a package are a security control, and it is the only tool here that
verifies a signature rather than just reading one. `appstore-add
--no-verify-signature` skips it deliberately, at the cost described in
[docs/security.md](docs/security.md). `aapt2` is genuinely optional — it reads
app names so you do not have to pass `--label`.

**Client build:** JDK 17 or later and the Android SDK.

## Quickstart

The full walkthrough, including TLS, the client build and the OS image, is in
**[docs/build.md](docs/build.md)**. The short version:

```sh
# on the repository host
sudo scripts/appstore-init --url https://apps.example.com
sudo scripts/appstore-nginx --install /etc/nginx/sites-available/appstore
sudo ln -s /etc/nginx/sites-available/appstore /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

sudo scripts/appstore-add --label "Example" --icon example.png example.apk
sudo scripts/appstore-publish
sudo scripts/appstore-verify --remote

# then build the client against it
sudo scripts/appstore-client-config > client/repo.properties
cd client && ./gradlew assembleRelease
```

The repository URL, signing public key and access key are compiled into the
APK, so changing any of them means a new client build.

## Updating an app

There is no separate update command. Publish a new version by adding it: the
versionCode comes from the APK, so a higher one is a new version rather than a
replacement.

```sh
sudo scripts/appstore-add --release-notes "Fixes the thing." example-1.3.apk
sudo scripts/appstore-publish
```

The app's name, description and icon carry over from the previous version, so
`--label` is only needed the first time. `appstore-add` also refuses an APK
signed by a different key than the version already published — that is the
mistake that ships an update no device can install.

Devices pick it up on the auto-update job, or immediately if someone pulls to
refresh in the app.

Older versions stay in the repository until you remove them, and they are dead
weight: the client only ever offers the highest versionCode on each release
channel, and `appstore-publish` warns when two versions share one. To retire
one:

```sh
sudo scripts/appstore-rm com.example.app 42
sudo scripts/appstore-publish --prune
```

`--prune` is what deletes the artifacts, and it runs after the new index is
signed, so the live index never points at a file that is already gone.

Two related things:

- **Re-uploading the same versionCode** — a bad build, say — needs `--replace`.
  Without it `appstore-add` refuses, so you cannot quietly change what a version
  means underneath devices that already have it.
- **A genuinely rotated signing key** needs `--allow-signer-change`, which
  records both certificates as valid. Devices that already have the old version
  still cannot take the update; they need a reinstall.

## Commands

| | |
|---|---|
| `appstore-init` | Create the repository, keys and config. |
| `appstore-add` | Add one version of one package, with its splits. |
| `appstore-rm` | Remove a version or a whole package. |
| `appstore-list` | Show what the repository holds. |
| `appstore-publish` | Rebuild, sign and install the index. The only step clients see. |
| `appstore-verify` | Re-check the published repository from scratch. |
| `appstore-key` | Add, list and revoke access keys. |
| `appstore-nginx` | Render the nginx site config, or print certificate pins. |
| `appstore-client-config` | Print the `repo.properties` to build the client with. |

Every command takes `--help`. `APPSTORE_HOME` (default `/var/lib/appstore`)
selects which repository they act on, so several can coexist on one host.

## How publishing works

`appstore-add` writes two things: the compressed APK into the web root, and a
small JSON fragment under `/var/lib/appstore/apps/<package>/` recording its
digest, sizes and signing certificate. Those fragments are the source of truth
and are meant to be edited by hand when you want a description, release notes or
a dependency that the command line does not cover.

`appstore-publish` merges the fragments into one document, checks that every
artifact it references is actually present and the right size, signs it, and
verifies its own output before replacing the live index. If anything is wrong it
publishes nothing, so a bad edit cannot take the repository down.

Nothing is visible to devices until you publish. `appstore-rm` only removes
fragments; the artifacts stay until `appstore-publish --prune`, so the live
index never points at a file that is already gone.

## Rotating an access key

Several keys are valid at once, which is what makes rotation possible without
locking devices out:

```sh
appstore-key add --label 2026-q3      # add the new key
appstore-key sync                     # rewrite the nginx map
nginx -t && systemctl reload nginx
# ship a client build carrying the new key, wait for devices to update
appstore-key revoke 2026-q1           # then retire the old one
```

## Testing

```sh
tests/run-tests.sh
```

Builds a throwaway repository, publishes real signed APKs into it, and verifies
the result the way the client would. No Android SDK needed; the fixture APKs are
committed.

## Security

Read [`docs/security.md`](docs/security.md) before putting this in front of real
devices. In short: the Ed25519 repository key is the root of trust and should
live somewhere other than the web server; the access key is an access gate, not
authentication, and ships inside the APK.

## Licence

The client keeps upstream's MIT licence (`client/LICENSE`). Everything else here
is under the same terms.
