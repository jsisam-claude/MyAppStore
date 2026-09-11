# Quality round 2 — the open backlog

An adversarial review of this repository was run on 2026-09-06: ten reviewers
across separate dimensions produced 57 findings, 47 unique after dedup. Each
was then put to three independent verifiers asked to *refute* it.

| | |
|---|---|
| unique findings | 47 |
| confirmed by 3 of 3 verifiers | 21 |
| unverified | 26 |

The 26 are **not refuted**. The verification agents ran out of session quota
before reaching them, so they carry zero votes either way; the reviewers that
raised them had reproduced each one. Treat them as leads to confirm while
implementing, not as noise.

Nothing from this round has been implemented. This file exists so the plan
survives the session it was made in.

## Plan

Branch off `main`, keep the test suite and `shellcheck` green, open a PR.

```
scripts/lib/common.sh   install_atomically refuses symlinks; acquire_lock (flock $APPSTORE_HOME/.lock) for add/publish/rm;
                        load_passphrase: real tty probe (exec 3</dev/tty) + wrong-passphrase diagnosis;
                        apksigner digest extraction fn accepting 'Signer #N' AND 'Signer (minSdkVersion=..)' [U41 HIGH];
                        ABI validation helper (arm64-v8a armeabi-v7a x86_64 x86 riscv64)
scripts/appstore-add    stage .gz/icon/.idsig via mktemp INSIDE dest dir (C00+U43); validate --icon before writing (C01);
                        clearer "exists but unrecorded" message (C01); --abi need_value + validate (C03);
                        use digest fn (U41); aapt2 badging cross-check package/versionCode vs apkinfo (U45);
                        sjson references exit 2 = fatal (C20); lock
scripts/appstore-publish mktemp staging (U43); lock
scripts/appstore-rm     lock; closing msg: never re-use a removed versionCode with different bytes (U42)
scripts/appstore-init   umask 022 subshell for $www mkdir (C07); reject URL path component (C09);
                        reject underscore in --auth-header (C10); pkcs8 -iter 600000 (C12)
scripts/appstore-key    ACCESS_KEY_REQUIRED strict 0/1 else die (C06); cap key length <=104 or bump bucket (C13)
scripts/appstore-nginx  fix --print-pins awk splitter (C04); server_tokens off + redirect to $server_name (C14);
                        icon path not immutable (C15)
scripts/appstore-verify curl header via @file in $TMP_DIR (U46)
scripts/lib/metadata.py type-check client-unsafe-cast fields, deps/staticDeps grammar (read Repo.kt), list types (C16);
                        _check_hex_digest strict ^[0-9a-f]{64}$ (U21); versionCode <= 2^63-1 (U44); OSError on write (U22)
scripts/lib/sjson.py    clean errors on malformed/missing doc (C18); truncated .gz per-artifact error (C11);
                        references: 0 pinned / 1 not / 2 error (C20)
scripts/lib/fragment.py save() dirname '' -> '.'; int() ValueError; OSError/Unicode in load (C17,C19,U22)
scripts/lib/apkinfo.py  open() inside try (U22); bare `package`/`split` attr wins on <manifest> (U45);
                        versionCodeMajor range (U44)
rom/Android.bp          preprocessed: true (U25 HIGH, reviewer ran Soong's check script); fix dex_preopt comment (U26)
rom/import-prebuilt.sh  digest regex (U41); EXPECTED_PACKAGE read from privapp xml (U31)
client build.gradle.kts empty repo.properties value -> fall back to env (U24)
client Glide redirects (U23): decide after reading PackageListAdapter/HttpUtils; either Registry.replace with a
                        ModelLoader using HttpUtils (cannot compile here!) or correct docs/security.md claim.
docs: C05 rotation procedure rewrite (security.md); U27 apksigner not optional (build.md:13-19,172; rom/README:33);
      U28 rom/README:36 path; U29 restore drill (build.md:291); U30 --force + 'still pins' row (README:105, build.md:336);
      U32 undocumented flags; U33 metadata-format variant table row; C15 comment
tests: U34 nginx skip() else; U35 generate.sh emits signer digests -> files read by suite; U36 check() shows stderr on FAIL;
       U37 label-inheritance with a label aapt2 can't supply; U38 tamper test drives appstore-verify; U39 gate-disabled/key-version
       section + appstore-list + check_fails; U40 MIN_TIMESTAMP consistency; stub-apksigner test for v3.1 'Signer (...)' output
SKIP (touches .github/workflows, unmergeable by us): U34's "install nginx in CI" half — mention in PR.
```

`C` numbers are confirmed findings, `U` numbers unverified. Two items are out
of reach from here and are called out rather than silently dropped:

- the half of U34 that installs nginx in CI touches `.github/workflows`, which
  this account's token cannot write;
- U23 (Glide following redirects) needs `PackageListAdapter`/`HttpUtils` read
  first, and the Kotlin client cannot be compiled in this environment, so it
  is either a `Registry.replace` change made blind or a correction to the
  claim in `docs/security.md`. Decide with the code open.

## Upstream sync check (2026-09-06)
Bare clone: scratchpad/up/Apps.git ; pinned tree extracted at scratchpad/up/pin
- Our pin b16ccc8c (2026-08-10) -> upstream main bdfeafd (2026-08-27): exactly 1 commit.
  It bumps actions/setup-java 5.7.0->6.0.0 in .github/workflows/build.yml, which we do not carry.
  BUT our adapted .github/workflows/client-build.yml:50 pins the same old SHA b6effb05...,
  and our open PR dependabot/github_actions/actions/setup-java-6.0.0 (e45e5c0) proposes the
  identical new SHA dd06d9cb... that upstream merged. => that PR was corroborated by
  upstream, and was merged as #12 on 2026-09-11.
- No Kotlin / resource / Gradle source changed upstream. gradle/libs.versions.toml byte-identical to ours.
- Recursive diff pin vs client/: modified .gitignore, app/build.gradle.kts, PackageListAdapter.kt,
  HttpUtils.kt, strings.xml, network_security_config.xml, settings.gradle.kts; new RepoAuth.kt;
  added UPSTREAM.md + repo.properties.example; dropped .idea/ .github/.
  == exactly UPSTREAM.md's table. No undocumented drift.
- Upstream has 14 open dependabot gradle branches, none merged, same set as ours (upstream even has
  AGP 9.4.0 while our PR proposed 9.3.2). Confirms our dependabot.yml decision to stop watching
  client/ gradle deps. Upstream's glide-5.0.9 branch is also unmerged (relevant to U23, no action).
- Our pin is 11 commits past the newest release tag (36, 2026-04-26): we forked untagged main.
=> No upstream sync needed. UPSTREAM.md's commit/date table is still accurate.

## Where the raw material is

The full finding text, per-finding evidence and verifier votes were produced
by workflow `wf_a12381b2-060`. If that session's scratchpad is gone, the
findings are reproducible: the review is a fan-out over the dimensions listed
in the plan above, and every item here carries enough detail to re-derive it.
