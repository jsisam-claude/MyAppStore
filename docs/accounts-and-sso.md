# Accounts, device management and SSO

Design notes for turning the store into the device's management and identity
client. Nothing here is built yet; this is the shape of the work and the
decisions that need making first.

## Where this is today

Repository access is a static key in an HTTP header, compiled into the APK. It
keeps the repository off the open internet and can be rotated fleet-wide. It
does not identify a device or a user, and it does not survive someone pulling
the APK apart. Everything below is about replacing it with something that does.

Worth restating up front: **authentication is not what protects an install.**
The Ed25519 signature over the index and the SHA-256 digests it commits to do
that, and they keep working unchanged no matter what we put in front of the
server. Authentication buys confidentiality, per-device revocation, and
per-user catalogs. It is not on the integrity path, which is why this can be
done incrementally without weakening anything.

## The constraint that shapes all of it

**Updates run unattended.** The auto-update job wakes on its own schedule,
often with the device locked and nobody present. Any scheme where repository
access depends on a live user session breaks background updates — which is the
entire point of running a store.

So device credentials and user credentials have to be separate things:

- A **device credential** authorises fetching the repository. Long-lived,
  hardware-bound, renewed without interaction, revocable per device.
- A **user credential** authorises a person, gates which catalog they see, and
  is what gets brokered to other apps for SSO. Interactive, shorter-lived, and
  never on the path of a background fetch.

Conflating them is the main way this design goes wrong.

## Phasing

Each phase is independently useful and independently shippable.

| | What | Buys | Rough size |
|---|---|---|---|
| **1** | Static header key *(done)* | Repository is not public | — |
| **2** | Per-device credential at enrolment | Per-device revocation, no shared secret | Small |
| **3** | The store becomes the DPC | Policy, remote wipe, mandatory apps | Medium |
| **4** | User identity + SSO broker | Per-user catalogs, one sign-in across first-party apps | Large |

Phase 2 is worth doing on its own even if 3 and 4 never happen. It removes the
one part of the current design that genuinely does not hold up.

## Phase 2: per-device credentials

At enrolment the device generates a key in the Android Keystore, hardware-backed
and non-exportable, and registers the public half with the server. Every
repository request is then authenticated with that key rather than a shared
secret.

Two ways to spend it, and they are not exclusive:

**Mutual TLS.** The device key becomes a client certificate; nginx does
`ssl_verify_client on` against your CA. Almost no application code — the client
sets an `SSLSocketFactory` backed by a `KeyChain` alias, and `ModernTLSSocketFactory`
is already the single place where that happens. Revocation is a CRL or a short
certificate lifetime. This is the cheapest real improvement available.

**DPoP-style proof, or a device-bound bearer token.** The device signs a short
assertion per request; a small service in front of nginx verifies it. More code,
but it survives TLS-terminating load balancers and gives per-request context to
log and rate-limit on.

Recommendation: **mTLS first.** It is a config change plus one class, and it
composes with everything in later phases.

### Key attestation is the interesting part

`KeyGenParameterSpec.setAttestationChallenge()` makes the hardware sign a
statement about the key it just generated — including whether verified boot is
enabled and **which key signed the running OS**.

Because you control the ROM signing key, this lets the server verify at
enrolment that a device is running *your* build with verified boot intact,
before it issues any credential. That is a materially stronger enrolment gate
than a shared secret in a QR code, and it is the one place where controlling
the OS pays off in a way an ordinary MDM cannot match.

Worth confirming early on your target hardware: attestation roots, and whether
your AVB key hash shows up as expected in the attestation extension. It is the
kind of thing that either works cleanly or turns into a week of yak-shaving,
and the answer should be known before the design depends on it.

## Phase 3: the store as device policy controller

The store is already a privileged system app with `INSTALL_PACKAGES` that talks
to your server on a schedule. A DPC needs to be a privileged app that talks to
your server on a schedule and installs things. The overlap is most of the work.

### Provisioning

On GrapheneOS the Google-hosted paths are not available — zero-touch enrolment
needs a reseller-provisioned device and Play services. What is available:

- **QR provisioning** through AOSP's `ManagedProvisioning`, with the DPC already
  in the image so nothing has to be downloaded. The QR carries the component
  name and an enrolment token. *Check that your build actually includes
  `ManagedProvisioning`; it is easy to assume and cheap to verify.*
- **`adb shell dpm set-device-owner`**, which is fine for a lab and for staging
  devices in bulk before handing them out.
- **Preconfiguring device owner in the image.** Since you build the OS, the DPC
  can be established at first boot without an operator step at all. This is the
  nicest option and the one an ordinary MDM cannot do.

The hard operational constraint: **device owner must be set before any account
is added and before setup completes.** In practice that means enrolment is part
of provisioning the device, not something a user does later. Decide early
whether that fits how devices reach people, because retrofitting it means
factory resets.

Fully managed (device owner) versus work profile (profile owner) is a policy
question, not a technical one: fully managed for corporate-owned devices, work
profile if people use their own. Work profile is the more likely fit if devices
are personal, and it changes the store's role — a work-profile store only
manages apps inside the profile.

### Same app or separate app?

| | Same APK | Separate DPC |
|---|---|---|
| Enrolment | One thing to provision | Two apps to keep in step |
| Blast radius | Store bug is a policy bug | Isolated |
| Release cadence | Coupled | Independent |
| Upstream syncs | Larger diff against GrapheneOS Apps | Store stays a thin fork |

Recommendation: **same APK, separate module.** Put the `DeviceAdminReceiver` and
policy code in their own Gradle module and their own package namespace, sharing
only the identity and transport layers. That keeps provisioning to one app while
leaving the seam to split later, and it keeps the upstream diff in
`client/UPSTREAM.md` from growing into something that makes syncing painful —
which is a real cost, since the fork's cheap upstream merges are what keep the
download and verification code current.

## Phase 4: user identity and SSO

### Protocol

**OIDC, and SAML through the IdP.** Every IdP worth using — Entra, Okta,
Keycloak, Ping — speaks both, and bridging SAML to OIDC at the IdP is a
configuration item. Speaking SAML natively on Android means XML signature
verification in the app, which is a bad place to be. If a SAML-only IdP is a
hard requirement, put Keycloak in front of it as a broker rather than
implementing SAML on the device.

Flow: **authorization code with PKCE in a Custom Tab**, not an embedded WebView.
A WebView means the app can read the user's IdP credentials, which defeats the
point of SSO and will fail an IdP's security review. Vanadium provides Custom
Tabs on GrapheneOS. The device authorization grant (RFC 8628) is a reasonable
fallback where no browser is available, but on a phone the Custom Tab flow is
better.

### Brokering tokens to first-party apps

This is what makes it single sign-on rather than one more login. Two mechanisms:

**A bound service guarded by a signature-level permission.** Declare a
permission with `protectionLevel="signature"`; only apps signed with your key
can bind and request a token. Simple, explicit, and the access rule is enforced
by the OS rather than by your code.

**An `AccountManager` authenticator.** The conventional Android answer. Apps
call `getAuthToken()` and the OS handles the plumbing, including apps you did
not write. More surface, more edge cases, but the right choice if third-party
apps ever need SSO.

Recommendation: **the signature-guarded broker first**, since first-party apps
are the actual requirement, and add an `AccountManager` authenticator later if
something outside your control needs it. Do both from one implementation of
token acquisition, refresh and storage, so there is a single place where refresh
races and clock skew get handled.

### Account provisioning

Users should not be created by hand in two places. **SCIM 2.0** from the IdP into
the server gives you create, update and deactivate for free, so that disabling
someone in the IdP revokes their catalog access and their device credential
without a separate step.

Group membership then drives which apps a device sees, which is the feature that
makes per-user catalogs worth building at all.

## What the server has to become

Today the repository is static files and nothing else, which is most of why it
is easy to reason about. That property is worth protecting.

**Keep nginx serving static files, put authentication beside it.**
`ngx_http_auth_request_module` sends each request to a small internal service
that validates the device credential and returns 200 or 401. nginx still serves
the bytes; the auth service never touches them. *Check the module is present —
`nginx-light` on Debian does not include it, `nginx-full` does.*

Per-user catalogs are the part that needs the most thought. The client fetches
one fixed URL, and the signature covers the whole document, so the options are:

- **Sign one document per group** and have the auth layer serve the right one at
  the same URL. Stays static, keeps signing offline, costs a signature per group
  per publish. ETag caching still works per group.
- **Generate per-user documents on demand.** Flexible, but it puts the signing
  key on a live server, which throws away the best property of the current
  design. Hard to recommend.

Recommendation: **per-group documents.** `appstore-publish` grows a notion of
groups, emits one signed document per group, and the auth layer picks. The
signing key stays offline.

## Decisions needed before any of this starts

1. **Fully managed or work profile?** Changes provisioning, the store's scope,
   and what policy can do.
2. **How do devices reach people?** Device owner has to be established during
   provisioning. If devices are drop-shipped to users, that has to be designed
   for, not discovered.
3. **Which IdP, and does it speak OIDC directly?** Decides whether a broker is
   needed.
4. **Do per-user catalogs actually matter,** or is one catalog per fleet enough?
   This is the single largest piece of work in phase 4 and it may not be needed.
5. **Does key attestation work on the target hardware with your AVB key?**
   Verify before designing enrolment around it.

## Suggested order

1. Confirm attestation behaviour on target hardware, and that
   `ManagedProvisioning` is in the build. Both are cheap to check and both can
   invalidate a design.
2. Ship per-device mTLS (phase 2). Retire the static key. Small, self-contained,
   removes the current design's weakest point.
3. Add the `DeviceAdminReceiver` and enrolment, in its own module (phase 3).
4. Add the identity broker and OIDC (phase 4), first-party apps first.
5. Per-group catalogs, only if the answer to decision 4 is yes.

Steps 1 and 2 are worth doing regardless of whether the rest ever happens.
