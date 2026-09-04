#!/bin/bash
#
# End-to-end test for the repository scripts.
#
# Builds a throwaway repository in a temporary directory, publishes real APKs
# into it, and checks the result the way the Android client would: slice the
# last 102 bytes off the signed metadata, verify the Ed25519 signature against
# the public key, then decompress and re-hash every artifact.
#
# Needs only bash, openssl, python3 and coreutils. No Android SDK: the fixture
# APKs are committed.
#
# shellcheck disable=SC2016  # `bash -c` payloads are single-quoted deliberately:
# their $1/$2 refer to the inner shell's arguments, not to this script's.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
BIN="$ROOT/scripts"
FIXTURES="$ROOT/tests/fixtures"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/appstore-tests.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

export APPSTORE_HOME="$WORK/state"
WWW="$WORK/www"
URL="https://apps.test.invalid"

passed=0
failed=0
skipped=0

ok()   { passed=$((passed + 1)); printf '  ok    %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf '  FAIL  %s\n' "$1"; }
# A check that could not run is reported, never silently omitted: a suite that
# prints a full pass after skipping a section is worse than one that fails.
skip() { skipped=$((skipped + 1)); printf '  SKIP  %s (%s)\n' "$1" "$2"; }

# Most checks exercise repository mechanics rather than signature verification,
# and must behave identically whether or not Android build-tools are installed.
# They opt out explicitly; the verification path has its own checks below.
add() { "$BIN/appstore-add" --no-verify-signature "$@"; }

check() { # description command...
    local description="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$description"; else bad "$description"; fi
}

check_fails() { # description command...
    local description="$1"; shift
    if "$@" >/dev/null 2>&1; then bad "$description (command unexpectedly succeeded)"; else ok "$description"; fi
}

check_eq() { # description expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi
}

section() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
section "init"

check "appstore-init succeeds" \
    "$BIN/appstore-init" --url "$URL" --www "$WWW" --no-passphrase

check "config was written" test -f "$APPSTORE_HOME/config"
check "secret key was written" test -f "$APPSTORE_HOME/keys/repo.sec.pem"
check "public key was written" test -f "$APPSTORE_HOME/keys/repo.pub"
check_eq "keys directory is 0700" "700" "$(stat -c%a "$APPSTORE_HOME/keys")"
check_eq "secret key is 0600" "600" "$(stat -c%a "$APPSTORE_HOME/keys/repo.sec.pem")"

pubkey="$(cat "$APPSTORE_HOME/keys/repo.pub")"
check_eq "public key is 56 base64 characters" "56" "${#pubkey}"
check_eq "public key decodes to 42 bytes" "42" "$(printf '%s' "$pubkey" | base64 -d | wc -c)"
check_eq "public key is tagged Ed" "Ed" "$(printf '%s' "$pubkey" | base64 -d | head -c 2)"

check "re-initialising is refused" \
    bash -c '! "$0" --url "$1" --www "$2" --no-passphrase' "$BIN/appstore-init" "$URL" "$WWW"

# A restored backup is "keys present, config missing". Generating a new key
# there would replace the public key compiled into every installed client.
cp "$APPSTORE_HOME/config" "$WORK/config.bak"
rm -f "$APPSTORE_HOME/config"
check_fails "init refuses when key material already exists" \
    "$BIN/appstore-init" --url "$URL" --www "$WWW" --no-passphrase
check "the signing key was left untouched" test -f "$APPSTORE_HOME/keys/repo.sec.pem"
check_eq "and the public key is unchanged" "$pubkey" "$(cat "$APPSTORE_HOME/keys/repo.pub")"
cp "$WORK/config.bak" "$APPSTORE_HOME/config"

# A missing option value used to kill the script with no output at all.
check "a missing option value names the option" bash -c '
    out="$("$1" --url 2>&1 || true)"
    case "$out" in *"--url needs a value"*) exit 0 ;; *) printf "got: %s\n" "$out"; exit 1 ;; esac
' _ "$BIN/appstore-init"
check "an enumerated option rejects a lookalike value" bash -c '
    out="$("$1" --channel --label x /dev/null 2>&1 || true)"
    case "$out" in *"--channel needs a value"*) exit 0 ;; *) exit 1 ;; esac
' _ "$BIN/appstore-add"

# ---------------------------------------------------------------------------
section "add"

check "add base plus split with an icon" \
    add --label "Fixture App" --description "A test package" \
        --icon "$FIXTURES/icon.png" \
        "$FIXTURES/v42/base.apk" "$FIXTURES/v42/split_config.hdpi.apk"

check "package fragment exists" test -f "$APPSTORE_HOME/apps/com.example.fixture/package.json"
check "variant fragment exists" test -f "$APPSTORE_HOME/apps/com.example.fixture/variants/42.json"
check "base artifact is served" test -f "$WWW/packages/com.example.fixture/42/base.apk.gz"
check "split artifact is served" test -f "$WWW/packages/com.example.fixture/42/split_config.hdpi.apk.gz"
check "v4 signature is served" test -f "$WWW/packages/com.example.fixture/42/base.apk.idsig"
check "icon is served" test -f "$WWW/packages/com.example.fixture/icon.png"

recorded="$(python3 "$BIN/lib/fragment.py" get \
    --file "$APPSTORE_HOME/apps/com.example.fixture/package.json" --key signatures)"
check_eq "recorded signer matches the fixture" \
    "2d6f2139268c154c7f80c015c4616db3aee0f8f54f295f27f43a03ef65577539" "$recorded"

check_eq "split is named the way the client parses splits" "1" \
    "$(python3 "$BIN/lib/fragment.py" get \
        --file "$APPSTORE_HOME/apps/com.example.fixture/variants/42.json" --key apks |
       grep -c '^split_config\.hdpi\.apk$')"

check_fails "adding the same version again is refused" \
    add --label "Fixture App" "$FIXTURES/v42/base.apk"

check "--replace allows overwriting" \
    add --label "Fixture App" --replace \
        "$FIXTURES/v42/base.apk" "$FIXTURES/v42/split_config.hdpi.apk"

check_fails "a version signed by a different key is refused" \
    add --label "Fixture App" "$FIXTURES/other-signer/base.apk"

# Certificate digests are what --expect-cert and the continuity check compare
# against, so recording ones nothing authenticated is a security bug, not a
# convenience. Without apksigner the command must refuse rather than warn.
if command -v apksigner >/dev/null 2>&1; then
    skip "refuses to record unverified digests without an opt-out" "apksigner is installed"
else
    check_fails "refuses to record unverified digests without an opt-out" \
        "$BIN/appstore-add" --label "Fixture App" --replace "$FIXTURES/v42/base.apk"
fi

# And when apksigner IS available, the digests must come from it rather than
# from apkinfo's unauthenticated read of the signing block.
if command -v apksigner >/dev/null 2>&1; then
    check "digests come from apksigner when it is available" \
        "$BIN/appstore-add" --label "Fixture App" --replace \
            "$FIXTURES/v42/base.apk" "$FIXTURES/v42/split_config.hdpi.apk"
    check_eq "and they match the fixture's real signer" \
        "2d6f2139268c154c7f80c015c4616db3aee0f8f54f295f27f43a03ef65577539" \
        "$(python3 "$BIN/lib/fragment.py" get \
            --file "$APPSTORE_HOME/apps/com.example.fixture/package.json" --key signatures)"
else
    skip "digests come from apksigner when it is available" "apksigner not installed"
    skip "and they match the fixture's real signer" "apksigner not installed"
fi

# A malformed APK has to fail as a clear error, not a Python traceback.
head -c 900 "$FIXTURES/v42/base.apk" > "$WORK/truncated.apk"
check_fails "a truncated APK is refused" \
    add --label "Broken" "$WORK/truncated.apk"
check "the truncated APK produces a clean error, not a traceback" bash -c '
    output="$(python3 "$1/lib/apkinfo.py" "$2" 2>&1 || true)"
    case "$output" in
        *Traceback*) exit 1 ;;
        error:*) exit 0 ;;
        *) exit 1 ;;
    esac
' _ "$BIN" "$WORK/truncated.apk"

check_fails "--expect-cert mismatch is refused" \
    add --label "Fixture App" \
        --expect-cert 0000000000000000000000000000000000000000000000000000000000000000 \
        "$FIXTURES/v43/base.apk"

check "add a second version" \
    add --label "Fixture App" --channel beta \
        --release-notes "Second test version" "$FIXTURES/v43/base.apk"

# Updating should not mean retyping the app's name every time.
"$BIN/appstore-rm" com.example.fixture 43 --yes >/dev/null 2>&1
check "a new version can be added without --label" \
    add --replace --channel beta "$FIXTURES/v43/base.apk"
check_eq "it inherits the label from the previous version" "Fixture App" \
    "$(python3 "$BIN/lib/fragment.py" get \
        --file "$APPSTORE_HOME/apps/com.example.fixture/variants/43.json" --key label)"

# ---------------------------------------------------------------------------
section "publish"

check "dry run succeeds" "$BIN/appstore-publish" --dry-run
check "nothing is published by a dry run" test ! -f "$WWW/metadata.1.0.sjson"

check "publish succeeds" "$BIN/appstore-publish"
check "metadata was installed" test -f "$WWW/metadata.1.0.sjson"

metadata="$WWW/metadata.1.0.sjson"
total="$(stat -c%s "$metadata")"

# The client slices blindly: bytes [0, size-102) are the signed document, then a
# newline, then 100 base64 characters, then a newline.
head -c "$((total - 102))" "$metadata" > "$WORK/doc.json"
tail -c 102 "$metadata" > "$WORK/trailer"
check_eq "byte at size-102 is a newline" "1" "$(head -c 1 "$WORK/trailer" | od -An -c | tr -d ' \n' | grep -c '\\n')"
check_eq "last byte is a newline" "1" "$(tail -c 1 "$metadata" | od -An -c | tr -d ' \n' | grep -c '\\n')"

tail -c 101 "$metadata" > "$WORK/sig101"
head -c 100 "$WORK/sig101" > "$WORK/sig.b64"
check_eq "signature is 100 base64 characters" "100" "$(wc -c < "$WORK/sig.b64")"
base64 -d < "$WORK/sig.b64" > "$WORK/sig.blob"
check_eq "signature blob is 74 bytes" "74" "$(stat -c%s "$WORK/sig.blob")"
check_eq "signature blob is tagged Ed" "Ed" "$(head -c 2 "$WORK/sig.blob")"

# Key ids must match, exactly as the client's FileVerifier checks.
tail -c +3 "$WORK/sig.blob" > "$WORK/s.rest"; head -c 8 "$WORK/s.rest" > "$WORK/s.keyid"
printf '%s' "$pubkey" | base64 -d | tail -c +3 > "$WORK/p.rest"; head -c 8 "$WORK/p.rest" > "$WORK/p.keyid"
check "signature key id matches the public key" cmp -s "$WORK/s.keyid" "$WORK/p.keyid"

# Verify the signature the way the client does, from the public key alone.
printf '%s' "$pubkey" | base64 -d | tail -c 32 > "$WORK/pub.raw"
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; cat "$WORK/pub.raw"; } > "$WORK/pub.der"
{ echo "-----BEGIN PUBLIC KEY-----"; base64 -w64 < "$WORK/pub.der"; echo "-----END PUBLIC KEY-----"; } > "$WORK/pub.pem"
tail -c 64 "$WORK/sig.blob" > "$WORK/sig.raw"
check "Ed25519 signature verifies over the sliced document" \
    openssl pkeyutl -verify -rawin -pubin -inkey "$WORK/pub.pem" \
        -sigfile "$WORK/sig.raw" -in "$WORK/doc.json"

check "a tampered document fails verification" bash -c '
    cp "$1/doc.json" "$1/tampered.json"
    printf "x" >> "$1/tampered.json"
    ! openssl pkeyutl -verify -rawin -pubin -inkey "$1/pub.pem" \
        -sigfile "$1/sig.raw" -in "$1/tampered.json" >/dev/null 2>&1
' _ "$WORK"

check "document is valid JSON" python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WORK/doc.json"
timestamp="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['time'])" "$WORK/doc.json")"
check "timestamp is at or above the client's MIN_TIMESTAMP" test "$timestamp" -ge 1770000000

check_eq "both versions are present" "2" \
    "$(python3 -c "
import json,sys
d = json.load(open(sys.argv[1]))
print(len(d['packages']['com.example.fixture']['variants']))
" "$WORK/doc.json")"

check_eq "label survives into the metadata" "Fixture App" \
    "$(python3 -c "
import json,sys
d = json.load(open(sys.argv[1]))
print(d['packages']['com.example.fixture']['variants']['42']['label'])
" "$WORK/doc.json")"

check_eq "the four apk arrays are the same length" "ok" \
    "$(python3 -c "
import json,sys
v = json.load(open(sys.argv[1]))['packages']['com.example.fixture']['variants']['42']
n = len(v['apks'])
print('ok' if all(len(v[k]) == n for k in ('apkHashes','apkSizes','apkGzSizes')) else 'mismatch')
" "$WORK/doc.json")"

# ---------------------------------------------------------------------------
section "verify"

check "appstore-verify passes on a freshly published repository" "$BIN/appstore-verify"

check_fails "verify catches a corrupted artifact" bash -c '
    target="$1/packages/com.example.fixture/42/base.apk.gz"
    cp "$target" "$2/backup.gz"
    printf "corrupt" >> "$target"
    "$3/appstore-verify" >/dev/null 2>&1
    status=$?
    cp "$2/backup.gz" "$target"
    exit $status
' _ "$WWW" "$WORK" "$BIN"

check "verify passes again once the artifact is restored" "$BIN/appstore-verify"

# ---------------------------------------------------------------------------
section "replace guard"

# Artifacts live at the path the signed index pins, so replacing a published
# version serves bytes that no longer match the signed digest.
check_fails "--replace is refused once the index pins that version" \
    add --label "Fixture App" --replace "$FIXTURES/v42/base.apk"
check "--force overrides it deliberately" \
    add --label "Fixture App" --replace --force "$FIXTURES/v42/base.apk"
check "the repository still verifies afterwards" "$BIN/appstore-verify"

# ---------------------------------------------------------------------------
section "timestamp monotonicity"

before="$(python3 "$BIN/lib/sjson.py" time --file "$metadata")"
python3 - "$metadata" <<'PY'
# Rewrite the published document with a far-future timestamp, keeping the
# container layout, to simulate a clock that has since gone backwards.
import json, sys
path = sys.argv[1]
raw = open(path, "rb").read()
doc = json.loads(raw[:-102].decode("utf-8"))
doc["time"] = doc["time"] + 100000
payload = json.dumps(doc, separators=(",", ":"), sort_keys=True).encode("utf-8")
open(path, "wb").write(payload + raw[-102:])
PY
"$BIN/appstore-publish" >/dev/null 2>&1
after="$(python3 "$BIN/lib/sjson.py" time --file "$metadata")"
check "republishing never moves the timestamp backwards" test "$after" -gt "$((before + 100000))"
check "the republished metadata still verifies" "$BIN/appstore-verify"

# ---------------------------------------------------------------------------
section "access keys"

keys_conf="$APPSTORE_HOME/access-keys.conf"
check "nginx map file was generated" test -f "$keys_conf"
check "map denies by default" grep -q 'default 0;' "$keys_conf"
check "map is keyed on the configured header" grep -q 'map \$http_x_appstore_key' "$keys_conf"

first_key="$(cut -f1 < "$APPSTORE_HOME/keys/access-keys" | head -n1)"
check_eq "the default key is 64 hex characters" "64" "${#first_key}"
check "the default key is in the map" grep -q "\"$first_key\" 1;" "$keys_conf"

check "a second key can be added" "$BIN/appstore-key" add --label rollout
check_eq "both keys are now accepted" "2" "$(grep -c '" 1;' "$keys_conf")"
check "revoking by label works" "$BIN/appstore-key" revoke rollout
check_eq "one key remains" "1" "$(grep -c '" 1;' "$keys_conf")"
check_fails "revoking an unknown label fails" "$BIN/appstore-key" revoke nope

# The map file is nginx configuration, so a malformed key must never reach it.
cp "$APPSTORE_HOME/keys/access-keys" "$WORK/keys.bak"
printf 'notahexkey"; }\tevil\t2026\n' >> "$APPSTORE_HOME/keys/access-keys"
check_fails "a malformed key is refused rather than written into nginx config" \
    "$BIN/appstore-key" sync
cp "$WORK/keys.bak" "$APPSTORE_HOME/keys/access-keys"
check "syncing works again once the key file is clean" "$BIN/appstore-key" sync

# ---------------------------------------------------------------------------
section "client config"

config="$("$BIN/appstore-client-config")"
check "client config carries the base URL" bash -c 'printf "%s" "$1" | grep -q "^REPO_BASE_URL=https://apps.test.invalid$"' _ "$config"
check "client config carries the public key" bash -c 'printf "%s" "$1" | grep -q "^REPO_PUBLIC_KEY=$2$"' _ "$config" "$pubkey"
check "client config carries an access key" bash -c 'printf "%s" "$1" | grep -qE "^REPO_ACCESS_KEY=[0-9a-f]{64}$"' _ "$config"
check "client config carries the header name" bash -c 'printf "%s" "$1" | grep -q "^REPO_ACCESS_KEY_HEADER=X-AppStore-Key$"' _ "$config"

# ---------------------------------------------------------------------------
section "nginx configuration"

site="$("$BIN/appstore-nginx")"
check "site config includes the access key map" bash -c 'printf "%s" "$1" | grep -q "include .*access-keys.conf;"' _ "$site"
check "site config rejects requests without a key" bash -c 'printf "%s" "$1" | grep -q "return 401;"' _ "$site"
check "site config disables gzip for artifacts" bash -c 'printf "%s" "$1" | grep -q "gzip off;"' _ "$site"
check "site config serves the right metadata filename" bash -c 'printf "%s" "$1" | grep -q "location = /metadata.1.0.sjson"' _ "$site"
check "site config refuses everything else" bash -c 'printf "%s" "$1" | grep -q "return 404;"' _ "$site"
check "site config allows only GET and HEAD" bash -c 'printf "%s" "$1" | grep -q "limit_except GET HEAD"' _ "$site"
if command -v nginx >/dev/null 2>&1; then
    # nginx -t opens the listening sockets, so the check needs unprivileged
    # ports, real certificate files, and temp paths it is allowed to write.
    ngx="$WORK/nginx"
    mkdir -p "$ngx/tmp" "$ngx/certs"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$ngx/certs/privkey.pem" -out "$ngx/certs/fullchain.pem" \
        -subj "/CN=apps.test.invalid" >/dev/null 2>&1
    "$BIN/appstore-nginx" --cert-dir "$ngx/certs" > "$ngx/site.conf"
    # Unprivileged ports, no IPv6 (CI runners do not always have it), and logs
    # inside the work directory. The site config logs to /var/log/nginx, which
    # is correct in production and unwritable for an unprivileged test run;
    # server-level access_log wins over the http-level one below, so it has to
    # be rewritten here rather than just overridden.
    sed -i \
        -e 's/listen 80;/listen 18080;/' \
        -e 's/listen 443 ssl/listen 18443 ssl/' \
        -e '/listen \[::\]/d' \
        -e "s#/var/log/nginx/appstore#$ngx/appstore#" \
        "$ngx/site.conf"
    cat > "$ngx/nginx.conf" <<NGINX
worker_processes 1;
error_log $ngx/error.log warn;
pid $ngx/nginx.pid;
events { worker_connections 64; }
http {
    access_log $ngx/access.log;
    client_body_temp_path $ngx/tmp/cb;
    proxy_temp_path $ngx/tmp/p;
    fastcgi_temp_path $ngx/tmp/f;
    uwsgi_temp_path $ngx/tmp/u;
    scgi_temp_path $ngx/tmp/s;
    include $ngx/site.conf;
}
NGINX
    if nginx -t -c "$ngx/nginx.conf" >"$ngx/test.log" 2>&1; then
        ok "nginx accepts the generated configuration"
    else
        bad "nginx rejected the generated configuration: $(tail -n2 "$ngx/test.log" | tr '\n' ' ')"
    fi
fi

# ---------------------------------------------------------------------------
section "remove and prune"

check "removing one version succeeds" "$BIN/appstore-rm" com.example.fixture 43 --yes
check "artifact still present before pruning" test -f "$WWW/packages/com.example.fixture/43/base.apk.gz"
check "publish with prune succeeds" "$BIN/appstore-publish" --prune
check "pruned artifact is gone" test ! -f "$WWW/packages/com.example.fixture/43/base.apk.gz"
check "remaining version is untouched" test -f "$WWW/packages/com.example.fixture/42/base.apk.gz"
check "repository still verifies after pruning" "$BIN/appstore-verify"

check "removing the whole package succeeds" "$BIN/appstore-rm" com.example.fixture --yes
check "publish with prune succeeds on an empty repository" "$BIN/appstore-publish" --prune
check_eq "no packages remain in the metadata" "0" \
    "$(python3 -c "
import json,sys
raw = open(sys.argv[1],'rb').read()
print(len(json.loads(raw[:-102].decode('utf-8'))['packages']))
" "$metadata")"

# ---------------------------------------------------------------------------
section "passphrase-protected signing key"

export APPSTORE_HOME="$WORK/state2"
WWW2="$WORK/www2"
export APPSTORE_KEY_PASSPHRASE="a test passphrase"

check "init with a passphrase succeeds" \
    "$BIN/appstore-init" --url "$URL" --www "$WWW2"
check "the key is encrypted on disk" \
    grep -q "ENCRYPTED PRIVATE KEY" "$APPSTORE_HOME/keys/repo.sec.pem"
check "add works against the second repository" \
    add --label "Fixture App" "$FIXTURES/v42/base.apk"
check "publish works with the passphrase from the environment" "$BIN/appstore-publish"
check "the result verifies" "$BIN/appstore-verify"

check_fails "publishing with the wrong passphrase fails" \
    env APPSTORE_KEY_PASSPHRASE=wrong "$BIN/appstore-publish"

# ---------------------------------------------------------------------------
if [ "$skipped" -gt 0 ]; then
    printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
else
    printf '\n%d passed, %d failed\n' "$passed" "$failed"
fi
[ "$failed" -eq 0 ]
