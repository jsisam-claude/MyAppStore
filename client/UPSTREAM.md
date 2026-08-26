# Upstream provenance

This directory is a fork of the GrapheneOS App Store client.

| | |
|---|---|
| Upstream | https://github.com/GrapheneOS/Apps |
| Commit | `b16ccc8c7b825da14fd8fc6dfec0b50553fba5a5` |
| Date | 2026-08-10 |
| License | MIT (see `LICENSE`, unchanged) |

The fork is deliberately thin. Everything that identifies *which* repository the
app talks to is a build-time setting upstream already supported, so the code
delta is limited to access control, branding, and build validation.

## What was changed

| File | Change |
|---|---|
| `app/build.gradle.kts` | Reads repo settings from `repo.properties`/env and **fails the build** if the URL or public key is missing. Validates the URL scheme, the key encoding, and the access-key header. `applicationId` changed to `app.myappstore`. `versionCode` reset to 1. Two new `BuildConfig` fields for the access key. |
| `app/src/main/java/app/grapheneos/apps/util/RepoAuth.kt` | **New.** Attaches the static access key, and only to URLs under `REPO_BASE_URL`. |
| `app/src/main/java/app/grapheneos/apps/util/HttpUtils.kt` | Attaches the access key after the caller's `configure()` so it cannot be dropped; sets `instanceFollowRedirects = false`. |
| `app/src/main/java/app/grapheneos/apps/ui/PackageListAdapter.kt` | Icon loads go through Glide, which does not use `openConnection()`, so the key is attached via `GlideUrl` + `LazyHeaders`. |
| `app/src/main/res/xml/network_security_config.xml` | Dropped the `apps.grapheneos.org` pin-set. Trust anchors restricted to `system` so a user-installed or MDM-pushed CA cannot observe the access key. Includes a commented pinning template. |
| `app/src/main/res/values/strings.xml` | `app_name`, and the two `pkg_source_*` labels that named GrapheneOS. |
| `settings.gradle.kts` | `rootProject.name`. |
| `.gitignore`, `repo.properties.example` | Repository configuration, kept out of git. |
| `.idea/`, `.github/` | IDE settings dropped; CI moved to the repository root and adapted to this layout. |

`namespace` is intentionally left as `app.grapheneos.apps`. It is the Kotlin/Java
package and the `R`/`BuildConfig` location, not the installed package name — that
is `applicationId`. Leaving it alone keeps every source file byte-identical to
upstream except the three listed above, which is what makes the sync below cheap.

## Syncing upstream

```sh
git remote add upstream https://github.com/GrapheneOS/Apps.git   # once
git fetch upstream
git diff b16ccc8c7b825da14fd8fc6dfec0b50553fba5a5..upstream/main -- . > /tmp/upstream.patch
git apply --3way --directory=client /tmp/upstream.patch
```

Then update the commit hash in the table above.

Re-check these after every sync, because they are the parts a repository change
can silently break:

- `RepoRetriever.kt` — `METADATA_VERSION`, and `MIN_TIMESTAMP` (a hardcoded
  anti-rollback floor; metadata older than it is rejected outright).
- `Repo.kt` — the metadata JSON schema. `scripts/lib/metadata.py` writes it, and
  `docs/metadata-format.md` documents it.
- `FileVerifier.kt` — the signature format the scripts produce.
- `HttpUtils.kt` — an upstream rewrite here would drop the access key.
