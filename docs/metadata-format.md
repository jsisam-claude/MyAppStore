# Repository format

Everything below is what the client in `client/` actually reads. The
authoritative definitions are `Repo.kt` (schema), `RepoRetriever.kt` (container
and fetching) and `FileVerifier.kt` (signature); `scripts/lib/metadata.py`
validates against the same rules before publishing, so a mistake here fails on
the host instead of on a device.

## URLs

```
<base>/metadata.<metadataVersion>.<keyVersion>.sjson
<base>/packages/<package>/icon.<iconType>
<base>/packages/<package>/<versionCode>/<apkName>.gz
<base>/packages/<package>/<versionCode>/<apkName>.idsig
```

`metadataVersion` is 1. `keyVersion` is `APPSTORE_KEY_VERSION`, which changes
only when the signing key does.

APKs are served **gzipped**, with `.gz` appended to the name that appears in the
metadata. The client requests them with `Accept-Encoding: identity` and resumes
with `Range` against the recorded compressed size, so the `.gz` bytes must be
served exactly as stored. `.idsig` files (APK signature scheme v4) are served
uncompressed.

## Container

`metadata.1.0.sjson` is not JSON. It is:

```
<JSON document, UTF-8, no trailing newline>
\n
<100 characters of base64>
\n
```

The client slices the last 102 bytes off without looking at them, so the lengths
are exact, not approximate. The base64 decodes to a 74-byte
[signify](https://man.openbsd.org/signify) signature blob:

```
"Ed"  2 bytes    algorithm
      8 bytes    key id
     64 bytes    Ed25519 signature over the JSON bytes only
```

The public key is the same shape, 42 bytes (`"Ed"` + key id + 32-byte key),
base64-encoded to the 56 characters that go in `REPO_PUBLIC_KEY`.

The signature covers the JSON bytes and nothing else — not the newline, not the
signature. `scripts/lib/metadata.py` writes the document compact, key-sorted and
UTF-8 encoded, and those exact bytes are what gets signed; nothing may reformat
them afterwards.

## The document

```json
{
  "time": 1787785389,
  "packages": {
    "com.example.fixture": {
      "description": "An example app.",
      "iconType": "png",
      "signatures": ["2d6f2139268c154c7f80c015c4616db3aee0f8f54f295f27f43a03ef65577539"],
      "variants": {
        "42": {
          "label": "Example",
          "versionName": "1.2.3",
          "channel": "stable",
          "minSdk": 31,
          "apks": ["base.apk", "split_config.hdpi.apk"],
          "apkHashes": ["32f8320d...", "d49665a5..."],
          "apkSizes": [8413, 8412],
          "apkGzSizes": [2418, 2193],
          "hasV4Signatures": true
        }
      }
    }
  }
}
```

`time` is seconds since the epoch. The client refuses an index older than the
one it already has, and refuses any index older than `MIN_TIMESTAMP`
(1770000000). `appstore-publish` will not let the timestamp go backwards even if
the host clock does.

Package keys are the manifest package name. Variant keys are the versionCode as
a decimal string.

### Package fields

| Field | | |
|---|---|---|
| `signatures` | **required** | SHA-256 digests of signing certificates, lowercase hex. See [security.md](security.md#what-the-certificate-digests-in-the-metadata-do) for what these are and are not used for. |
| `description` | | Shown on the details screen. Overridable per variant. |
| `iconType` | | `png`, `webp` or `jpg`. The icon must exist at `packages/<package>/icon.<iconType>`. |
| `source` | | One of `GrapheneOS`, `GrapheneOS_build`, `Mirror`, `Google`. Default `GrapheneOS_build`. |
| `isTopLevel` | | `false` hides the package from the main screen. Default `true`. |
| `noCode` | | Resource-only package. Enforced at install: the APK must declare `hasCode="false"`. |
| `isSharedLibrary` | | Static shared library. Enforced at install. |
| `optOutOfBulkUpdates` | | Keeps the package out of "Update all" and the auto-update job. Set it for the store itself; `appstore-add --self-updating` does. |
| `requestUpdateOwnership` | | Default `true`. |
| `showAutoUpdateNotifications` | | Default: true unless `noCode`. |
| `group` | | Packages sharing a group share a release channel setting. |
| `deps` / `deps2` | | `"<package> [minVersion] [flags]"`. The only flag is `SkipIfMissing`. |
| `staticDeps` | | `"<package> [op] [version]"` with `>=`, `==` or `<`. The dependency must be a system package. Filters the package out when unmet. |
| `requiredSystemFeatures`, `supportedDevices` | | Filters, evaluated against `Build.DEVICE` and system features. |
| `originalPackage` | | For adopting a preinstalled package via the original-package system. |
| `packagesAllowedToTriggerUpdate` | | System packages allowed to trigger an update of this `noCode` package over the exported RPC provider. Leave unset. |

### Variant fields

| Field | | |
|---|---|---|
| `label` | **required** | Display name. The client reads it with no fallback. |
| `apks` | **required** | File names. `base.apk` must be present. |
| `apkHashes` | **required** | SHA-256 of each **uncompressed** APK, lowercase hex. |
| `apkSizes` | **required** | Uncompressed size in bytes. |
| `apkGzSizes` | **required** | Size of the `.gz` file as served. Used for resuming, so it must be exact. |
| `versionName` | | Defaults to the versionCode. |
| `channel` | | `stable`, `beta` or `alpha`. Default `stable`. |
| `minSdk`, `maxSdk` | | Filters the variant out on devices outside the range. |
| `abis` | | Restricts the variant to devices whose primary ABI is listed. |
| `releaseNotes`, `description` | | Shown on the details screen. |
| `hasV4Signatures` | | Every APK in the variant needs a matching `.idsig`. Only used on SDK 35+, where it enables fs-verity. |

The four `apk*` arrays must be the same length and in the same order.

A package may have at most one variant per release channel: if two versions are
both on `stable`, the client only ever offers the higher versionCode.
`appstore-publish` warns when that happens.

### APK names and splits

The client infers a split's kind from its **file name**, by looking for
`config.` in it:

| Name | Treated as |
|---|---|
| `base.apk` | always installed |
| `split_config.arm64_v8a.apk` | ABI split, installed only on a matching device |
| `split_config.en.apk` | language split, installed for matching locales |
| `split_config.xxhdpi.apk` | density split, closest match installed |
| `split_feature.apk` | no `config.`, so always installed |

`appstore-add` derives these names from each APK's manifest rather than from the
file you pass it: no `split` attribute becomes `base.apk`, and a split named
`config.hdpi` becomes `split_config.hdpi.apk`. You do not need to name your input
files in any particular way.

### Package source labels

`source` maps to a display string, and this fork relabels the two that named
GrapheneOS. The JSON values are unchanged so that the client code stays in sync
with upstream:

| `source` | Shown as |
|---|---|
| `GrapheneOS` | First party |
| `GrapheneOS_build` | Built in-house *(default)* |
| `Mirror` | Mirror |
| `Google` | Google (mirror) |

Change them in `client/app/src/main/res/values/strings.xml`.

## Editing by hand

The published document is generated, so edit the fragments instead:

```
/var/lib/appstore/apps/<package>/package.json          package fields
/var/lib/appstore/apps/<package>/variants/<code>.json   variant fields
```

They are written indented and key-sorted for exactly this reason.
`appstore-add` merges into them rather than overwriting, so a description added
by hand survives the next version. After editing:

```sh
appstore-publish --dry-run   # validate without signing
appstore-publish
```

Fields the scripts do not have flags for — dependencies, device filters,
`isTopLevel` — can be set either by editing the file or with the escape hatch:

```sh
python3 scripts/lib/fragment.py package \
    --file /var/lib/appstore/apps/com.example.app/package.json \
    --set 'deps=["com.example.lib 5"]' \
    --set isTopLevel=false
```

`--set` takes `KEY=JSON`, falling back to treating the value as a plain string
if it is not valid JSON.

## Things that are not supported

- **fs-verity certificates** (`fsVerityCerts` / `hasFsVeritySignatures`). These
  are the pre-SDK-35 mechanism and need signatures from a certificate embedded
  in the OS image. Use v4 signatures (`.idsig`) instead, which
  `appstore-add` picks up automatically when apksigner has produced them.
- **APK signature scheme v1 only.** `appstore-add` refuses an APK with no v2 or
  newer signature; modern Android requires one anyway.
