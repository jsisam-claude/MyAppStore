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
| `client/` | The forked Android client. See [`client/UPSTREAM.md`](client/UPSTREAM.md) for exactly what was changed and how to sync upstream. |
| `scripts/` | `appstore-*`, the repository management commands. |
| `rom/` | Bundling the client into a GrapheneOS build as a prebuilt privileged app. See [`rom/README.md`](rom/README.md). |
| `docs/` | [Security model](docs/security.md), [metadata format](docs/metadata-format.md), [accounts, MDM and SSO](docs/accounts-and-sso.md). |
| `tests/` | End-to-end tests against real signed APK fixtures. |

## Requirements

**Repository host:** bash, openssl, python3, gzip, coreutils, nginx. Android
build-tools (`apksigner`, `aapt2`) are optional but recommended: `apksigner`
verifies APK signatures before you publish, and `aapt2` reads app names so you
do not have to pass `--label`.

**Client build:** JDK 17 or later and the Android SDK.

## Quickstart

### 1. Set up the repository

```sh
sudo scripts/appstore-init --url https://apps.example.com
```

That creates `/var/lib/appstore` (state, keys) and `/var/www/appstore` (what
nginx serves), generates the Ed25519 signing key and the first access key, and
prints both. It prompts for a passphrase for the signing key; pass
`--no-passphrase` for unattended publishing.

### 2. Configure nginx

```sh
sudo scripts/appstore-nginx --install /etc/nginx/sites-available/appstore
sudo ln -s /etc/nginx/sites-available/appstore /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

The generated config expects a certificate at
`/etc/letsencrypt/live/<your domain>/`; use `--cert-dir` if yours is elsewhere.
Remove the `listen [::]` lines if the host has no IPv6.

### 3. Add apps

```sh
sudo scripts/appstore-add --label "Example" --icon example.png example.apk
sudo scripts/appstore-publish
sudo scripts/appstore-verify
```

Pass split APKs alongside the base APK in the same command:

```sh
sudo scripts/appstore-add --label "Example" \
    base.apk split_config.arm64_v8a.apk split_config.en.apk
```

### 4. Build the client

```sh
sudo scripts/appstore-client-config > client/repo.properties
cd client && ./gradlew assembleRelease
```

The repository URL, signing public key and access key are compiled into the
APK. Changing any of them means a new client build. To ship it inside your
GrapheneOS build, see [`rom/README.md`](rom/README.md).

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
