#!/usr/bin/env python3
"""Inspect a published metadata.N.K.sjson file.

The container format is what the client's RepoRetriever reads:

    <JSON as UTF-8>
    \\n
    <100 bytes of base64 signature>
    \\n

The client slices the last 102 bytes off blindly, so the trailing newline and
the exact signature length are load-bearing; both are checked here.

Signature verification itself is done by appstore-verify with openssl, against
the public key file, so that the check does not depend on this parser.
"""

import argparse
import gzip
import hashlib
import json
import os
import sys

SIGNATURE_B64_LEN = 100
TRAILER_LEN = SIGNATURE_B64_LEN + 2
MIN_TIMESTAMP = 1770000000


class SjsonError(Exception):
    pass


def split(path):
    """Returns (json_bytes, signature_base64) exactly as the client slices them."""
    with open(path, "rb") as handle:
        raw = handle.read()
    if len(raw) <= TRAILER_LEN:
        raise SjsonError("%s is too short to contain a signature" % path)
    payload = raw[:len(raw) - TRAILER_LEN]
    if raw[len(raw) - TRAILER_LEN:len(raw) - TRAILER_LEN + 1] != b"\n":
        raise SjsonError("%s: missing newline between the document and the signature" % path)
    if raw[-1:] != b"\n":
        raise SjsonError("%s: missing trailing newline" % path)
    signature = raw[len(raw) - SIGNATURE_B64_LEN - 1:-1]
    return payload, signature.decode("ascii", "replace")


def load(path):
    payload, _ = split(path)
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SjsonError("%s: document is not valid UTF-8 JSON: %s" % (path, exc))


def cmd_time(args):
    print(load(args.file)["time"])
    return 0


def cmd_split(args):
    payload, signature = split(args.file)
    with open(args.json_out, "wb") as handle:
        handle.write(payload)
    with open(args.sig_out, "w", encoding="ascii") as handle:
        handle.write(signature)
    return 0


def cmd_verify(args):
    document = load(args.file)
    problems = []
    checked = 0

    timestamp = document.get("time")
    if not isinstance(timestamp, int):
        problems.append("'time' is missing or not an integer")
    elif timestamp < MIN_TIMESTAMP:
        problems.append("time %d is below the client's MIN_TIMESTAMP of %d; "
                        "every client would reject this as a downgrade"
                        % (timestamp, MIN_TIMESTAMP))

    packages = document.get("packages")
    if not isinstance(packages, dict):
        raise SjsonError("'packages' is missing or not an object")

    referenced = set()

    for package, meta in sorted(packages.items()):
        icon_type = meta.get("iconType")
        if icon_type:
            icon = os.path.join(args.www, "packages", package, "icon." + icon_type)
            referenced.add(os.path.realpath(icon))
            if not os.path.isfile(icon):
                problems.append("%s: icon %s is missing" % (package, icon))

        for version_code, variant in sorted(meta.get("variants", {}).items()):
            names = variant.get("apks", [])
            hashes = variant.get("apkHashes", [])
            sizes = variant.get("apkSizes", [])
            gz_sizes = variant.get("apkGzSizes", [])

            for index, name in enumerate(names):
                served = os.path.join(args.www, "packages", package, str(version_code),
                                      name + ".gz")
                referenced.add(os.path.realpath(served))
                if variant.get("hasV4Signatures"):
                    referenced.add(os.path.realpath(served[:-len(".gz")] + ".idsig"))

                if not os.path.isfile(served):
                    problems.append("%s/%s: %s is missing" % (package, version_code, served))
                    continue

                actual_gz = os.path.getsize(served)
                if actual_gz != gz_sizes[index]:
                    problems.append("%s/%s: %s is %d bytes, metadata says %d"
                                    % (package, version_code, name, actual_gz, gz_sizes[index]))

                digest = hashlib.sha256()
                total = 0
                try:
                    with gzip.open(served, "rb") as handle:
                        while True:
                            chunk = handle.read(1 << 20)
                            if not chunk:
                                break
                            total += len(chunk)
                            digest.update(chunk)
                except OSError as exc:
                    problems.append("%s/%s: %s is not readable gzip: %s"
                                    % (package, version_code, name, exc))
                    continue

                if total != sizes[index]:
                    problems.append("%s/%s: %s decompresses to %d bytes, metadata says %d"
                                    % (package, version_code, name, total, sizes[index]))
                if digest.hexdigest() != hashes[index]:
                    problems.append("%s/%s: %s SHA-256 is %s, metadata says %s"
                                    % (package, version_code, name,
                                       digest.hexdigest(), hashes[index]))
                if variant.get("hasV4Signatures"):
                    idsig = served[:-len(".gz")] + ".idsig"
                    if not os.path.isfile(idsig):
                        problems.append("%s/%s: hasV4Signatures is set but %s is missing"
                                        % (package, version_code, name + ".idsig"))
                checked += 1

    orphans = []
    packages_root = os.path.join(args.www, "packages")
    for root, _dirs, files in os.walk(packages_root):
        for name in files:
            path = os.path.realpath(os.path.join(root, name))
            if path not in referenced:
                orphans.append(os.path.relpath(path, packages_root))

    for orphan in sorted(orphans):
        print("warning: unreferenced file in the web root: packages/%s" % orphan,
              file=sys.stderr)

    print("checked %d artifact(s) across %d package(s)" % (checked, len(packages)),
          file=sys.stderr)
    for problem in problems:
        print("error: %s" % problem, file=sys.stderr)
    return 1 if problems else 0


def cmd_references(args):
    """Exit 0 if the published document pins this package/versionCode."""
    document = load(args.file)
    meta = (document.get("packages") or {}).get(args.package)
    if not meta:
        return 1
    return 0 if str(args.version_code) in (meta.get("variants") or {}) else 1


def cmd_orphans(args):
    """Prints files under www/packages that the metadata does not reference."""
    document = load(args.file)
    referenced = set()
    for package, meta in document.get("packages", {}).items():
        if meta.get("iconType"):
            referenced.add(os.path.realpath(os.path.join(
                args.www, "packages", package, "icon." + meta["iconType"])))
        for version_code, variant in meta.get("variants", {}).items():
            for name in variant.get("apks", []):
                base = os.path.join(args.www, "packages", package, str(version_code), name)
                referenced.add(os.path.realpath(base + ".gz"))
                referenced.add(os.path.realpath(base + ".idsig"))

    packages_root = os.path.join(args.www, "packages")
    if not os.path.isdir(packages_root):
        return 0
    for root, _dirs, files in os.walk(packages_root):
        for name in files:
            path = os.path.realpath(os.path.join(root, name))
            if path not in referenced:
                print(path)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("time", help="print the document's timestamp")
    p.add_argument("--file", required=True)
    p.set_defaults(func=cmd_time)

    p = sub.add_parser("split", help="write the signed bytes and the signature separately")
    p.add_argument("--file", required=True)
    p.add_argument("--json-out", required=True)
    p.add_argument("--sig-out", required=True)
    p.set_defaults(func=cmd_split)

    p = sub.add_parser("verify", help="check every artifact against the document")
    p.add_argument("--file", required=True)
    p.add_argument("--www", required=True)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("references", help="exit 0 if the document pins this package/versionCode")
    p.add_argument("--file", required=True)
    p.add_argument("--package", required=True)
    p.add_argument("--version-code", required=True)
    p.set_defaults(func=cmd_references)

    p = sub.add_parser("orphans", help="list web root files the document does not reference")
    p.add_argument("--file", required=True)
    p.add_argument("--www", required=True)
    p.set_defaults(func=cmd_orphans)

    args = parser.parse_args()
    try:
        return args.func(args)
    except SjsonError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
