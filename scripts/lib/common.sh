# shellcheck shell=bash
#
# Shared helpers for the appstore-* scripts.
#
# Sourced, never executed. Every script that sources this gets `set -euo pipefail`
# and a private temporary directory that is removed on exit.
#
# shellcheck disable=SC2034  # these are consumed by the scripts that source this file

set -euo pipefail

# --- constants that must stay in step with the client ------------------------
#
# METADATA_VERSION and MIN_TIMESTAMP mirror the constants in
# client/app/src/main/java/app/grapheneos/apps/core/RepoRetriever.kt. The client
# fetches metadata.$METADATA_VERSION.$KEY_VERSION.sjson and rejects any metadata
# whose "time" is below MIN_TIMESTAMP, so publishing must never produce one.
readonly METADATA_VERSION=1
readonly MIN_TIMESTAMP=1770000000

# Release channels the client understands (ReleaseChannel in Repo.kt).
readonly VALID_CHANNELS="stable beta alpha"
# Package sources the client understands (PackageSource in Repo.kt).
readonly VALID_SOURCES="GrapheneOS GrapheneOS_build Mirror Google"

# --- paths -------------------------------------------------------------------

APPSTORE_HOME="${APPSTORE_HOME:-/var/lib/appstore}"
CONFIG_FILE="$APPSTORE_HOME/config"
KEYS_DIR="$APPSTORE_HOME/keys"
APPS_DIR="$APPSTORE_HOME/apps"
SECRET_KEY_FILE="$KEYS_DIR/repo.sec.pem"
PUBLIC_KEY_FILE="$KEYS_DIR/repo.pub"
KEYID_FILE="$KEYS_DIR/repo.keyid"
ACCESS_KEYS_FILE="$KEYS_DIR/access-keys"

# Settings read from $CONFIG_FILE.
APPSTORE_BASE_URL=""
APPSTORE_WWW=""
APPSTORE_KEY_VERSION="0"
APPSTORE_AUTH_HEADER="X-AppStore-Key"
APPSTORE_SERVER_NAME=""
APPSTORE_NGINX_KEYS_FILE=""
APPSTORE_ACCESS_KEY_REQUIRED="1"

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR

# --- output ------------------------------------------------------------------

_is_tty() { [ -t 2 ]; }
if _is_tty; then
    _c_red=$'\033[31m'; _c_yellow=$'\033[33m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
else
    _c_red=""; _c_yellow=""; _c_dim=""; _c_off=""
fi

info() { printf '%s\n' "$*" >&2; }
detail() { printf '%s%s%s\n' "$_c_dim" "$*" "$_c_off" >&2; }
warn() { printf '%swarning:%s %s\n' "$_c_yellow" "$_c_off" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1${2:+ ($2)}"
}

# --- temporary files ---------------------------------------------------------

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/appstore.XXXXXXXX")"
readonly TMP_DIR
chmod 700 "$TMP_DIR"
# shellcheck disable=SC2317  # invoked via trap
_cleanup() { rm -rf -- "$TMP_DIR"; }
trap _cleanup EXIT

tmpfile() { mktemp "$TMP_DIR/${1:-tmp}.XXXXXX"; }

# --- configuration -----------------------------------------------------------

# Parsed rather than sourced: the config file should be data, not code.
load_config() {
    [ -f "$CONFIG_FILE" ] ||
        die "$CONFIG_FILE not found. Run appstore-init first (or set APPSTORE_HOME)."

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        [ "$line" = "${line#*=}" ] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            APPSTORE_BASE_URL|APPSTORE_WWW|APPSTORE_KEY_VERSION|APPSTORE_AUTH_HEADER|\
            APPSTORE_SERVER_NAME|APPSTORE_NGINX_KEYS_FILE|APPSTORE_ACCESS_KEY_REQUIRED)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                warn "ignoring unknown setting in $CONFIG_FILE: $key"
                ;;
        esac
    done < "$CONFIG_FILE"

    [ -n "$APPSTORE_BASE_URL" ] || die "APPSTORE_BASE_URL is not set in $CONFIG_FILE"
    [ -n "$APPSTORE_WWW" ] || die "APPSTORE_WWW is not set in $CONFIG_FILE"
    case "$APPSTORE_WWW" in /*) ;; *) die "APPSTORE_WWW must be an absolute path" ;; esac
    case "$APPSTORE_BASE_URL" in
        https://*) ;;
        *) die "APPSTORE_BASE_URL must start with https:// (got: $APPSTORE_BASE_URL)" ;;
    esac
    APPSTORE_BASE_URL="${APPSTORE_BASE_URL%/}"
    [ -n "$APPSTORE_NGINX_KEYS_FILE" ] ||
        APPSTORE_NGINX_KEYS_FILE="$APPSTORE_HOME/access-keys.conf"
}

require_keys() {
    [ -f "$SECRET_KEY_FILE" ] || die "signing key not found at $SECRET_KEY_FILE. Run appstore-init."
    [ -f "$PUBLIC_KEY_FILE" ] || die "public key not found at $PUBLIC_KEY_FILE. Run appstore-init."
    [ -f "$KEYID_FILE" ] || die "key id not found at $KEYID_FILE. Run appstore-init."
}

# nginx exposes request headers as $http_<lowercased name with - replaced by _>.
nginx_header_var() {
    printf 'http_%s' "$(printf '%s' "$APPSTORE_AUTH_HEADER" | tr 'A-Z-' 'a-z_')"
}

metadata_filename() {
    printf 'metadata.%s.%s.sjson' "$METADATA_VERSION" "$APPSTORE_KEY_VERSION"
}

metadata_path() {
    printf '%s/%s' "$APPSTORE_WWW" "$(metadata_filename)"
}

# --- signing -----------------------------------------------------------------

_passphrase=""
_passphrase_loaded=0

secret_key_is_encrypted() {
    head -n 1 -- "$SECRET_KEY_FILE" | grep -q 'ENCRYPTED PRIVATE KEY'
}

load_passphrase() {
    [ "$_passphrase_loaded" = 1 ] && return 0
    if [ -n "${APPSTORE_KEY_PASSPHRASE:-}" ]; then
        _passphrase="$APPSTORE_KEY_PASSPHRASE"
    else
        [ -r /dev/tty ] ||
            die "the signing key is passphrase-protected but there is no terminal to prompt on. Set APPSTORE_KEY_PASSPHRASE."
        printf 'Passphrase for the repository signing key: ' >&2
        IFS= read -rs _passphrase < /dev/tty
        printf '\n' >&2
    fi
    _passphrase_loaded=1
}

# Runs openssl against the secret key, supplying the passphrase on fd 3 when the
# key is encrypted. The passphrase never reaches the command line or the disk.
openssl_with_key() {
    if secret_key_is_encrypted; then
        load_passphrase
        openssl "$@" -passin fd:3 3<<<"$_passphrase"
    else
        openssl "$@"
    fi
}

# sign_file <path> -> 100 characters of base64, the signify signature blob
# ("Ed" + 8 byte key id + 64 byte Ed25519 signature) over the file's exact bytes.
sign_file() {
    local input="$1" sigfile signature
    sigfile="$(tmpfile sig)"
    openssl_with_key pkeyutl -sign -rawin -inkey "$SECRET_KEY_FILE" \
        -in "$input" -out "$sigfile"
    [ "$(stat -c%s "$sigfile")" = 64 ] || die "unexpected Ed25519 signature size"
    signature="$( { printf 'Ed'; cat -- "$KEYID_FILE"; cat -- "$sigfile"; } | base64 -w0 )"
    [ "${#signature}" = 100 ] || die "unexpected signature encoding length: ${#signature}"
    printf '%s' "$signature"
}

# Writes a PEM public key to $1, rebuilt from the signify public key blob.
# Ed25519 SubjectPublicKeyInfo is a fixed 12 byte prefix plus the 32 byte key.
write_pubkey_pem() {
    local out="$1" raw der
    raw="$(tmpfile pubraw)"
    der="$(tmpfile pubder)"
    base64 -d < "$PUBLIC_KEY_FILE" | tail -c 32 > "$raw"
    [ "$(stat -c%s "$raw")" = 32 ] || die "malformed public key in $PUBLIC_KEY_FILE"
    { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; cat -- "$raw"; } > "$der"
    [ "$(stat -c%s "$der")" = 44 ] || die "failed to rebuild the public key"
    { printf -- '-----BEGIN PUBLIC KEY-----\n'
      base64 -w64 < "$der"
      printf -- '-----END PUBLIC KEY-----\n'
    } > "$out"
}

# --- misc --------------------------------------------------------------------

# Atomically replaces $2 with $1, which must already be on the same filesystem.
install_atomically() {
    local src="$1" dest="$2"
    chmod 644 -- "$src"
    mv -f -- "$src" "$dest"
}

is_package_name() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]
}

is_version_code() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

confirm() {
    local reply
    printf '%s [y/N] ' "$1" >&2
    IFS= read -r reply < /dev/tty || reply=""
    case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
