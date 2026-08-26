#!/usr/bin/env python3
"""Read and write the JSON fragments that make up the repository metadata.

Fragments live under $APPSTORE_HOME/apps/<package>/ and are the repository's
source of truth. They are written indented and key-sorted so that editing one by
hand and re-running appstore-publish is a supported workflow.

Writes merge: fields not named on the command line keep their current values, so
adding a new version never discards a description someone wrote earlier.
"""

import argparse
import json
import os
import sys
import tempfile


class FragmentError(Exception):
    pass


def load(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        raise FragmentError("%s: invalid JSON: %s" % (path, exc))
    if not isinstance(data, dict):
        raise FragmentError("%s: expected a JSON object" % path)
    return data


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=os.path.dirname(path),
        prefix=".tmp-", delete=False)
    try:
        json.dump(data, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")
        handle.close()
        os.chmod(handle.name, 0o640)
        os.replace(handle.name, path)
    except BaseException:
        os.unlink(handle.name)
        raise


def apply_set(data, assignments, unsets):
    for assignment in assignments or []:
        if "=" not in assignment:
            raise FragmentError("--set expects KEY=JSON_VALUE (got %r)" % assignment)
        key, raw = assignment.split("=", 1)
        try:
            data[key] = json.loads(raw)
        except json.JSONDecodeError:
            # A bare word is far more convenient than requiring quotes.
            data[key] = raw
    for key in unsets or []:
        data.pop(key, None)


def cmd_get(args):
    data = load(args.file)
    if args.key not in data:
        return 1
    value = data[args.key]
    if isinstance(value, list):
        for item in value:
            print(item)
    elif isinstance(value, bool):
        print("true" if value else "false")
    else:
        print(value)
    return 0


def cmd_package(args):
    data = load(args.file)

    if args.signature:
        data["signatures"] = list(dict.fromkeys(args.signature))
    for key, value in (("description", args.description),
                       ("source", args.source),
                       ("iconType", args.icon_type)):
        if value is not None:
            if value == "":
                data.pop(key, None)
            else:
                data[key] = value
    if args.opt_out_of_bulk_updates is not None:
        data["optOutOfBulkUpdates"] = args.opt_out_of_bulk_updates == "true"

    apply_set(data, args.set, args.unset)

    if not data.get("signatures"):
        raise FragmentError("refusing to write %s without signatures" % args.file)
    save(args.file, data)
    return 0


def cmd_variant(args):
    data = load(args.file)

    if args.apk:
        names, hashes, sizes, gz_sizes = [], [], [], []
        for entry in args.apk:
            parts = entry.split(":")
            if len(parts) != 4:
                raise FragmentError("--apk expects NAME:SHA256:SIZE:GZSIZE (got %r)" % entry)
            name, digest, size, gz_size = parts
            names.append(name)
            hashes.append(digest)
            sizes.append(int(size))
            gz_sizes.append(int(gz_size))
        data["apks"] = names
        data["apkHashes"] = hashes
        data["apkSizes"] = sizes
        data["apkGzSizes"] = gz_sizes

    for key, value in (("label", args.label),
                       ("versionName", args.version_name),
                       ("channel", args.channel),
                       ("description", args.description),
                       ("releaseNotes", args.release_notes)):
        if value is not None:
            if value == "":
                data.pop(key, None)
            else:
                data[key] = value

    for key, value in (("minSdk", args.min_sdk), ("maxSdk", args.max_sdk)):
        if value is not None:
            if value < 0:
                data.pop(key, None)
            else:
                data[key] = value

    if args.abi:
        data["abis"] = list(dict.fromkeys(args.abi))
    if args.has_v4 is not None:
        if args.has_v4 == "true":
            data["hasV4Signatures"] = True
        else:
            data.pop("hasV4Signatures", None)

    apply_set(data, args.set, args.unset)

    if not data.get("label"):
        raise FragmentError("refusing to write %s without a label" % args.file)
    if not data.get("apks"):
        raise FragmentError("refusing to write %s without apks" % args.file)
    save(args.file, data)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("get", help="print one field")
    p.add_argument("--file", required=True)
    p.add_argument("--key", required=True)
    p.set_defaults(func=cmd_get)

    p = sub.add_parser("package", help="write package.json")
    p.add_argument("--file", required=True)
    p.add_argument("--signature", action="append")
    p.add_argument("--description")
    p.add_argument("--source")
    p.add_argument("--icon-type")
    p.add_argument("--opt-out-of-bulk-updates", choices=("true", "false"))
    p.add_argument("--set", action="append")
    p.add_argument("--unset", action="append")
    p.set_defaults(func=cmd_package)

    p = sub.add_parser("variant", help="write variants/<versionCode>.json")
    p.add_argument("--file", required=True)
    p.add_argument("--apk", action="append")
    p.add_argument("--label")
    p.add_argument("--version-name")
    p.add_argument("--channel")
    p.add_argument("--description")
    p.add_argument("--release-notes")
    p.add_argument("--min-sdk", type=int)
    p.add_argument("--max-sdk", type=int)
    p.add_argument("--abi", action="append")
    p.add_argument("--has-v4", choices=("true", "false"))
    p.add_argument("--set", action="append")
    p.add_argument("--unset", action="append")
    p.set_defaults(func=cmd_variant)

    args = parser.parse_args()
    try:
        return args.func(args)
    except FragmentError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
