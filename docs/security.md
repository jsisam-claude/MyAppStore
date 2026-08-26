# Security model

## What the root of trust actually is

The repository index is signed with an Ed25519 key. The client has the matching
public key compiled into it and verifies the signature before it parses
anything. That signed index carries a SHA-256 digest for every APK, and the
client hashes each APK as it decompresses it, refusing any that does not match.

So the chain is: **the repository signing key vouches for the index, and the
index vouches for every byte of every APK.** TLS is not part of that chain. A
compromised certificate authority, a hostile network, or a compromised web
server cannot cause a modified APK to be installed, because none of them can
produce a valid signature over an index naming a different digest.

Three other checks sit alongside it:

- **Rollback.** The client stores the timestamp of the index it has and refuses
  an older one. It also refuses any index older than a hardcoded floor
  (`MIN_TIMESTAMP` in `RepoRetriever.kt`). Serving an old, validly signed index
  to hold a device on a vulnerable version therefore only works within the
  window since that device last updated.
- **Update continuity.** Android refuses to install an update signed by a
  different key than the version already on the device. This is enforced by the
  OS, not by the store.
- **The install prompt.** New installs go through `USER_ACTION_REQUIRED`, so a
  device shows a confirmation dialog even when the store is privileged. Only
  updates of already-installed packages apply silently.

## What the certificate digests in the metadata do

Each package in the index carries a `signatures` array of signing certificate
SHA-256 digests. It is worth being precise about these, because the name invites
an assumption that is not true.

**The client does not check a downloaded APK against them at install time.** In
this codebase they feed one thing: a privileged fast path that reuses an APK
already present in another user profile. What stops a substituted APK is the
SHA-256 digest in the signed index, not this field.

Where they do earn their keep is on the publishing side. `appstore-add` records
the signer of the first version of a package and refuses a later version signed
by a different key unless you pass `--allow-signer-change`. That catches the
mistake that would otherwise ship an update no device can install, and it
catches an APK swapped for one built by someone else before it reaches the
repository. `--expect-cert` makes the check explicit for a first upload.

## Where the signing key should live

Whoever holds the signing key can publish anything to every device. Nothing else
in this design comes close in blast radius.

It does not have to live on the web server. The repository state directory and
the served directory are separate, so publishing offline and shipping only the
output is a straightforward change:

```sh
# on an admin machine, not the web host
export APPSTORE_HOME=~/appstore
appstore-init --url https://apps.example.com --www ~/appstore-www
appstore-add --label "Example" example.apk
appstore-publish

rsync -a --delete ~/appstore-www/ webhost:/var/www/appstore/
```

The web host then holds only public artifacts. Compromising it buys an attacker
denial of service and a stale-but-signed index, nothing more.

If the key does have to live on the server, keep the passphrase
(`appstore-init` prompts for one by default) and supply it interactively rather
than through `APPSTORE_KEY_PASSPHRASE`, so that reading the disk is not enough.

**Back up `$APPSTORE_HOME/keys` before you publish anything.** The public key is
compiled into every installed client. Losing the private key means no device can
ever be given another update until it is reflashed or the app is reinstalled by
hand.

### Replacing the signing key

Key material is versioned in the filename the client fetches
(`metadata.1.<keyVersion>.sjson`). To move to a new key: bump
`APPSTORE_KEY_VERSION`, run `appstore-init` into a fresh `APPSTORE_HOME`, publish
under the new version, ship a client build carrying the new public key, and keep
serving the old file until the fleet has moved.

## The phase 1 access key

Requests must carry a static key in an HTTP header, which nginx checks before
serving anything. Be clear about what that is and is not.

**It is** a way to keep the repository off the open internet, so that the list of
apps you deploy and the APKs themselves are not casually downloadable, and a
coarse revocation lever.

**It is not** authentication, and it does not identify a user or a device. The
key ships inside the client APK. Anyone who can read the APK — from the OS
image, from a device with root or a working ADB backup, or by pulling it off a
device they own — can read the key. Treat the repository as readable by anyone
who has ever held one of your devices.

Practical consequences:

- Do not put anything in the repository that would be a problem to leak. The
  access key is not a substitute for the app secrecy you may be assuming.
- Rotation is the mitigation, and it is cheap because several keys are valid at
  once. Add a key, ship a build with it, then revoke the old one.
- Revocation is fleet-wide, not per-device. Every device carrying a revoked key
  stops updating.

Per-device credentials that survive extraction need per-device identity, which
is what [`accounts-and-sso.md`](accounts-and-sso.md) is about. Mutual TLS with a
per-device key in the hardware keystore is the smallest step up and does not
need any of the account machinery.

## Hardening in the client fork

- **Redirects are not followed.** `instanceFollowRedirects = false` on every
  repository connection. A redirect would otherwise resend the access key to
  whatever host it pointed at.
- **The access key only goes to the repository.** It is attached only to URLs
  under `REPO_BASE_URL`, with the trailing `/` required so that a lookalike host
  such as `https://apps.example.com.attacker.test/` cannot match the prefix.
- **Icons carry it too.** Glide has its own HTTP stack and does not go through
  `openConnection()`, so icon loads attach the header separately. Without that,
  either icons break or `/packages/*/icon.*` has to be left ungated.
- **Only OS trust anchors.** A CA installed by the user or pushed by an MDM
  cannot observe repository traffic, and therefore cannot read the access key.
- **The build refuses to guess.** No default repository URL or public key: a
  build with `repo.properties` missing fails instead of quietly producing a
  client pointed somewhere useless. The URL must be `https://`, and the public
  key must decode to a well-formed Ed25519 signify key.

### Certificate pinning

Not enabled, deliberately. Integrity already comes from the signature chain
above, so pinning adds confidentiality hardening at the cost of a failure mode
where a rotated certificate takes the whole fleet offline until every device
gets a new client build. If you want it anyway,
`appstore-nginx --print-pins` computes the values and
`network_security_config.xml` has a commented template. Pin an intermediate you
control the rotation of, and always include a backup pin.

### The exported RPC provider

Upstream exports a `ContentProvider` that lets a preinstalled system app trigger
an immediate update of a resource-only package. It is kept as upstream, and it
is inert here: the caller must be a system package, must be listed in that
package's `packagesAllowedToTriggerUpdate`, and the target must be a `noCode`
package with no dependencies. The scripts never emit
`packagesAllowedToTriggerUpdate`, so every call returns false. It only becomes
reachable if you add that field to a package fragment by hand.

## What the server is exposed to

nginx serves two path patterns read-only and returns 404 for everything else.
Directory listing is off, only GET and HEAD are allowed, and the access key is
checked before any of it.

Artifacts are served pre-compressed and byte-exact, with `gzip off` so nginx
cannot re-encode them, because the client requests them with
`Accept-Encoding: identity` and resumes with `Range` against the compressed size
recorded in the signed index.

The access key travels in a request header, so it does not appear in nginx's
access log, which logs the request line rather than headers. It will appear in
any debugging you set up that logs headers, and in a TLS-terminating proxy in
front of nginx.

Denial of service is the realistic server-side risk and is not addressed here.
Rate limiting is left out on purpose: the natural place to apply it,
`limit_req` on `/packages/`, interacts badly with large resumed downloads.

## Verifying a repository

`appstore-verify` re-checks everything from scratch: it verifies the Ed25519
signature with openssl against the public key file, checks the algorithm tag and
key id the way the client does, then decompresses and re-hashes every artifact
against the signed index. `--remote` also fetches over HTTPS and confirms the
served bytes match the file on disk, and that a request with no access key is
refused.

Run it after publishing, and after anything touches the web root.

## Reporting

The client is a fork of GrapheneOS's App Store. Vulnerabilities in the upstream
client, and in the download and verification code in particular, should go to
GrapheneOS. Anything specific to this fork or to the publishing scripts belongs
wherever this repository's issues live.
