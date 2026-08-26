#!/usr/bin/env python3
"""Assemble the repository metadata document from the per-package fragments.

Reads $APPSTORE_HOME/apps/<package>/package.json plus
$APPSTORE_HOME/apps/<package>/variants/<versionCode>.json and writes the single
JSON document the client downloads.

The output is written as exact bytes and then signed by the caller, so nothing
here may reformat it afterwards.

Validation is deliberately strict: a field the client requires but that is
missing here surfaces as an unhelpful parse failure on the device, long after
publishing. Everything checked below mirrors a requirement in
client/app/src/main/java/app/grapheneos/apps/core/Repo.kt.
"""

import argparse
import json
import os
import sys

VALID_CHANNELS = ("stable", "beta", "alpha")
VALID_SOURCES = ("GrapheneOS", "GrapheneOS_build", "Mirror", "Google")
VALID_ICON_TYPES = ("png", "webp", "jpg")

# Mirrors MIN_TIMESTAMP in RepoRetriever.kt. The client rejects anything older.
MIN_TIMESTAMP = 1770000000

PACKAGE_KEYS = {
    "signatures", "description", "source", "iconType", "isTopLevel", "noCode",
    "isSharedLibrary", "showAutoUpdateNotifications", "requestUpdateOwnership",
    "optOutOfBulkUpdates", "originalPackage", "group", "deps", "deps2",
    "staticDeps", "requiredSystemFeatures", "supportedDevices",
    "packagesAllowedToTriggerUpdate", "hasFsVeritySignatures",
}
VARIANT_KEYS = {
    "label", "versionName", "description", "releaseNotes", "channel", "minSdk",
    "maxSdk", "abis", "apks", "apkHashes", "apkSizes", "apkGzSizes",
    "hasV4Signatures", "deps", "deps2", "staticDeps", "requiredSystemFeatures",
    "supportedDevices",
}


class MetadataError(Exception):
    pass


def _load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        raise MetadataError("%s: invalid JSON: %s" % (path, exc))
    except OSError as exc:
        raise MetadataError("%s: %s" % (path, exc))


def _check_hex_digest(value, where):
    if not isinstance(value, str) or len(value) != 64:
        raise MetadataError("%s: expected a 64 character SHA-256 hex digest" % where)
    try:
        int(value, 16)
    except ValueError:
        raise MetadataError("%s: not a hex digest: %r" % (where, value))


def _validate_variant(package, version_code, variant, www):
    where = "%s/%s" % (package, version_code)

    unknown = set(variant) - VARIANT_KEYS
    if unknown:
        print("warning: %s: passing through unrecognised fields: %s"
              % (where, ", ".join(sorted(unknown))), file=sys.stderr)

    label = variant.get("label")
    if not isinstance(label, str) or not label:
        # RPackage does json.getString("label") with no fallback.
        raise MetadataError("%s: 'label' is required and must be a non-empty string" % where)

    channel = variant.get("channel", "stable")
    if channel not in VALID_CHANNELS:
        raise MetadataError("%s: channel must be one of %s (got %r)"
                            % (where, ", ".join(VALID_CHANNELS), channel))

    names = variant.get("apks")
    hashes = variant.get("apkHashes")
    sizes = variant.get("apkSizes")
    gz_sizes = variant.get("apkGzSizes")
    for field, value in (("apks", names), ("apkHashes", hashes),
                         ("apkSizes", sizes), ("apkGzSizes", gz_sizes)):
        if not isinstance(value, list) or not value:
            raise MetadataError("%s: '%s' is required and must be a non-empty list"
                                % (where, field))
    if not (len(names) == len(hashes) == len(sizes) == len(gz_sizes)):
        # RPackage requires these four arrays to be the same length.
        raise MetadataError("%s: apks, apkHashes, apkSizes and apkGzSizes "
                            "must all have the same length" % where)

    if not any(name == "base.apk" for name in names):
        raise MetadataError("%s: no base.apk among %s" % (where, names))

    for index, name in enumerate(names):
        if not isinstance(name, str) or not name.endswith(".apk"):
            raise MetadataError("%s: apk name must end in .apk (got %r)" % (where, name))
        if "/" in name or name.startswith("."):
            raise MetadataError("%s: unsafe apk name %r" % (where, name))
        _check_hex_digest(hashes[index], "%s: apkHashes[%d]" % (where, index))
        for field, value in (("apkSizes", sizes[index]), ("apkGzSizes", gz_sizes[index])):
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise MetadataError("%s: %s[%d] must be a non-negative integer"
                                    % (where, field, index))

        if www is None:
            continue

        # The client resumes downloads against apkGzSizes and streams the
        # gzip through a SHA-256 check, so a stale or missing artifact is a
        # hard failure on the device. Catch it before signing instead.
        served = os.path.join(www, "packages", package, str(version_code), name + ".gz")
        if not os.path.isfile(served):
            raise MetadataError("%s: %s is referenced but missing" % (where, served))
        actual = os.path.getsize(served)
        if actual != gz_sizes[index]:
            raise MetadataError("%s: %s is %d bytes but metadata says %d"
                                % (where, served, actual, gz_sizes[index]))

        if variant.get("hasV4Signatures"):
            idsig = served[:-len(".gz")] + ".idsig"
            if not os.path.isfile(idsig):
                raise MetadataError("%s: hasV4Signatures is set but %s is missing"
                                    % (where, idsig))


def _validate_package(package, meta, www):
    unknown = set(meta) - PACKAGE_KEYS
    if unknown:
        print("warning: %s: passing through unrecognised fields: %s"
              % (package, ", ".join(sorted(unknown))), file=sys.stderr)

    signatures = meta.get("signatures")
    if not isinstance(signatures, list) or not signatures:
        # Repo.kt does json.getJSONArray("signatures") unconditionally.
        raise MetadataError("%s: 'signatures' is required and must be a non-empty list"
                            % package)
    for index, digest in enumerate(signatures):
        _check_hex_digest(digest, "%s: signatures[%d]" % (package, index))

    source = meta.get("source")
    if source is not None and source not in VALID_SOURCES:
        raise MetadataError("%s: source must be one of %s (got %r)"
                            % (package, ", ".join(VALID_SOURCES), source))

    icon_type = meta.get("iconType")
    if icon_type is not None:
        if icon_type not in VALID_ICON_TYPES:
            raise MetadataError("%s: iconType must be one of %s (got %r)"
                                % (package, ", ".join(VALID_ICON_TYPES), icon_type))
        if www is not None:
            icon = os.path.join(www, "packages", package, "icon." + icon_type)
            if not os.path.isfile(icon):
                raise MetadataError("%s: iconType is %s but %s is missing"
                                    % (package, icon_type, icon))


def build(apps_dir, timestamp, www=None):
    if timestamp < MIN_TIMESTAMP:
        raise MetadataError(
            "timestamp %d is below the client's MIN_TIMESTAMP of %d; the client "
            "would reject this repository as a downgrade" % (timestamp, MIN_TIMESTAMP))

    if not os.path.isdir(apps_dir):
        raise MetadataError("%s does not exist" % apps_dir)

    packages = {}
    for package in sorted(os.listdir(apps_dir)):
        package_dir = os.path.join(apps_dir, package)
        manifest = os.path.join(package_dir, "package.json")
        if not os.path.isfile(manifest):
            continue

        meta = _load(manifest)
        if not isinstance(meta, dict):
            raise MetadataError("%s: expected a JSON object" % manifest)
        if "variants" in meta:
            raise MetadataError("%s: 'variants' is generated, remove it from package.json"
                                % manifest)
        _validate_package(package, meta, www)

        variants = {}
        variants_dir = os.path.join(package_dir, "variants")
        if os.path.isdir(variants_dir):
            for entry in sorted(os.listdir(variants_dir)):
                if not entry.endswith(".json"):
                    continue
                version_code = entry[:-len(".json")]
                if not version_code.isdigit():
                    raise MetadataError("%s: variant filename must be a versionCode"
                                        % os.path.join(variants_dir, entry))
                variant = _load(os.path.join(variants_dir, entry))
                if not isinstance(variant, dict):
                    raise MetadataError("%s: expected a JSON object"
                                        % os.path.join(variants_dir, entry))
                _validate_variant(package, version_code, variant, www)
                variants[version_code] = variant

        if not variants:
            # Repo.kt drops packages with no variants, so shipping one is dead weight.
            print("warning: %s has no versions, skipping" % package, file=sys.stderr)
            continue

        # At most one variant per release channel survives on the device, so
        # two versions on the same channel means the lower one is unreachable.
        seen = {}
        for version_code, variant in variants.items():
            channel = variant.get("channel", "stable")
            if channel in seen:
                print("warning: %s has both %s and %s on the '%s' channel; the client "
                      "will only offer the higher versionCode"
                      % (package, seen[channel], version_code, channel), file=sys.stderr)
            seen[channel] = version_code

        entry = dict(meta)
        entry["variants"] = variants
        packages[package] = entry

    return {"time": timestamp, "packages": packages}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apps-dir", required=True)
    parser.add_argument("--time", required=True, type=int)
    parser.add_argument("--www", help="verify referenced artifacts under this web root")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    try:
        document = build(args.apps_dir, args.time, args.www)
    except MetadataError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1

    # Compact, key-sorted, UTF-8, and with no trailing newline: these are the
    # exact bytes that get signed.
    payload = json.dumps(document, separators=(",", ":"), sort_keys=True,
                         ensure_ascii=False).encode("utf-8")
    with open(args.output, "wb") as handle:
        handle.write(payload)

    print("%d package(s), %d byte(s)"
          % (len(document["packages"]), len(payload)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
