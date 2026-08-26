# Test fixtures

Small, real APKs used by `tests/run-tests.sh`. They are committed so the test
suite runs without the Android SDK.

They are genuine APKs: built with `aapt2`, zipaligned, and signed with APK
signature schemes v2, v3 and v4. That matters, because the point of the tests is
to check that `scripts/lib/apkinfo.py` reads Android's real binary formats
correctly rather than a hand-rolled approximation of them.

| Path | Package | versionCode | Signer |
|---|---|---|---|
| `v42/base.apk`, `v42/split_config.hdpi.apk` | `com.example.fixture` | 42 | A |
| `v43/base.apk` | `com.example.fixture` | 43 | A |
| `other-signer/base.apk` | `com.example.fixture` | 44 | B |

`other-signer` exists to test that `appstore-add` refuses a version signed by a
different key than the one already published.

Signing certificate SHA-256 digests:

- Signer A: `2d6f2139268c154c7f80c015c4616db3aee0f8f54f295f27f43a03ef65577539`
- Signer B: `dbe8d24be594c0b3b0315af86ec51dadc86a07402f12b3dd6ccb4dfd7f732718`

The signing keys are throwaway keystores that were not kept; these APKs are test
data and nothing should ever trust them.

## Regenerating

Needs Android build-tools (`aapt2`, `zipalign`, `apksigner`), an `android.jar`,
and `keytool`. See `generate.sh` in this directory.
