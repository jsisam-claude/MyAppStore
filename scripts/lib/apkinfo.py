#!/usr/bin/env python3
"""Extract the facts about an APK that the repository metadata needs.

Prints one JSON object describing the APK: package name, version, split name,
and the SHA-256 digests of its signing certificates.

Two things are read out of the APK directly, so that the Android SDK is not a
hard requirement on the repository host:

  * AndroidManifest.xml, which is Android's binary XML rather than text.
  * The APK Signing Block, for the signing certificates.

Certificates are *extracted*, not verified. Verifying an APK signature means
recomputing the scheme v2/v3 chunked digests, which apksigner already does well;
when apksigner is on PATH, appstore-add uses it and this parser only fills in the
manifest fields. See docs/security.md.
"""

import argparse
import hashlib
import json
import struct
import sys
import zipfile

# ResChunk_header types.
RES_STRING_POOL_TYPE = 0x0001
RES_XML_TYPE = 0x0003
RES_XML_START_ELEMENT_TYPE = 0x0102
RES_XML_RESOURCE_MAP_TYPE = 0x0180

# ResStringPool_header flags.
UTF8_FLAG = 0x0100

# Res_value dataTypes.
TYPE_REFERENCE = 0x01
TYPE_STRING = 0x03
TYPE_INT_DEC = 0x10
TYPE_INT_HEX = 0x11
TYPE_INT_BOOLEAN = 0x12

# Framework attribute resource IDs, used when the string pool carries no
# attribute names (aapt2 may emit empty names and rely on the resource map).
ATTR_IDS = {
    0x01010003: "name",
    0x0101000C: "hasCode",
    0x01010001: "label",
    0x0101020C: "minSdkVersion",
    0x01010270: "targetSdkVersion",
    0x0101021B: "versionCode",
    0x0101021C: "versionName",
    0x01010576: "versionCodeMajor",
}

APK_SIG_BLOCK_MAGIC = b"APK Sig Block 42"
SIG_BLOCK_IDS = [
    (0x1B93AD61, "v3.1"),
    (0xF05368C0, "v3"),
    (0x7109871A, "v2"),
]


class ApkError(Exception):
    pass


# --------------------------------------------------------------------------
# Binary XML (AXML)
# --------------------------------------------------------------------------

def _decode_len8(data, off):
    n = data[off]
    off += 1
    if n & 0x80:
        n = ((n & 0x7F) << 8) | data[off]
        off += 1
    return n, off


def _decode_len16(data, off):
    (n,) = struct.unpack_from("<H", data, off)
    off += 2
    if n & 0x8000:
        (low,) = struct.unpack_from("<H", data, off)
        off += 2
        n = ((n & 0x7FFF) << 16) | low
    return n, off


def _parse_string_pool(data, start):
    chunk_type, header_size, chunk_size = struct.unpack_from("<HHI", data, start)
    if chunk_type != RES_STRING_POOL_TYPE:
        raise ApkError("expected a string pool chunk")
    count, _styles, flags, strings_start, _styles_start = struct.unpack_from(
        "<IIIII", data, start + 8
    )
    offsets = struct.unpack_from("<%dI" % count, data, start + header_size)
    base = start + strings_start
    utf8 = bool(flags & UTF8_FLAG)

    strings = []
    for offset in offsets:
        pos = base + offset
        if pos >= start + chunk_size:
            raise ApkError("string pool entry out of range")
        if utf8:
            _utf16_len, pos = _decode_len8(data, pos)
            byte_len, pos = _decode_len8(data, pos)
            strings.append(data[pos:pos + byte_len].decode("utf-8", "replace"))
        else:
            char_len, pos = _decode_len16(data, pos)
            strings.append(data[pos:pos + char_len * 2].decode("utf-16-le", "replace"))
    return strings, start + chunk_size


def _parse_axml(data):
    """Yields (tag_name, {attr_name: value}) for every start element."""
    if len(data) < 8:
        raise ApkError("AndroidManifest.xml is truncated")
    chunk_type, header_size, _size = struct.unpack_from("<HHI", data, 0)
    if chunk_type != RES_XML_TYPE:
        raise ApkError("AndroidManifest.xml is not binary XML")

    strings = []
    resource_map = []
    pos = header_size

    def string_at(index):
        if index == 0xFFFFFFFF or index >= len(strings):
            return None
        return strings[index]

    while pos + 8 <= len(data):
        chunk_type, chunk_header_size, chunk_size = struct.unpack_from("<HHI", data, pos)
        if chunk_size < 8 or pos + chunk_size > len(data):
            raise ApkError("malformed chunk in AndroidManifest.xml")

        if chunk_type == RES_STRING_POOL_TYPE:
            strings, _ = _parse_string_pool(data, pos)
        elif chunk_type == RES_XML_RESOURCE_MAP_TYPE:
            entries = (chunk_size - chunk_header_size) // 4
            resource_map = list(
                struct.unpack_from("<%dI" % entries, data, pos + chunk_header_size)
            )
        elif chunk_type == RES_XML_START_ELEMENT_TYPE:
            body = pos + chunk_header_size
            _ns, name_idx, attr_start, attr_size, attr_count = struct.unpack_from(
                "<IIHHH", data, body
            )
            tag = string_at(name_idx)
            attrs = {}
            for i in range(attr_count):
                a = body + attr_start + i * attr_size
                a_ns, a_name, a_raw, _size, _res0, a_type, a_data = struct.unpack_from(
                    "<IIIHBBI", data, a
                )
                key = string_at(a_name)
                if not key and a_name < len(resource_map):
                    key = ATTR_IDS.get(resource_map[a_name])
                if not key:
                    continue
                # Namespaced and bare attributes can share a name (for example
                # "package" on <manifest> versus android:name elsewhere); the
                # android-namespaced one wins because that is what the platform
                # reads.
                if key in attrs and a_ns == 0xFFFFFFFF:
                    continue
                if a_type == TYPE_STRING:
                    attrs[key] = string_at(a_raw)
                elif a_type in (TYPE_INT_DEC, TYPE_INT_HEX):
                    attrs[key] = a_data
                elif a_type == TYPE_INT_BOOLEAN:
                    attrs[key] = a_data != 0
                elif a_type == TYPE_REFERENCE:
                    attrs[key] = {"reference": a_data}
                else:
                    attrs[key] = string_at(a_raw)
            yield tag, attrs

        pos += chunk_size


def parse_manifest(data):
    info = {
        "packageName": None,
        "versionCode": None,
        "versionName": None,
        "minSdk": None,
        "targetSdk": None,
        "split": None,
        "hasCode": True,
        "label": None,
    }
    version_code = None
    version_code_major = 0

    for tag, attrs in _parse_axml(data):
        if tag == "manifest":
            info["packageName"] = attrs.get("package")
            info["split"] = attrs.get("split")
            value = attrs.get("versionCode")
            if isinstance(value, int):
                version_code = value
            value = attrs.get("versionCodeMajor")
            if isinstance(value, int):
                version_code_major = value
            value = attrs.get("versionName")
            if isinstance(value, str):
                info["versionName"] = value
        elif tag == "uses-sdk":
            for key, field in (("minSdkVersion", "minSdk"), ("targetSdkVersion", "targetSdk")):
                value = attrs.get(key)
                if isinstance(value, int):
                    info[field] = value
        elif tag == "application":
            value = attrs.get("hasCode")
            if isinstance(value, bool):
                info["hasCode"] = value
            value = attrs.get("label")
            # A resource reference cannot be resolved without parsing
            # resources.arsc; aapt2 or --label supplies it instead.
            if isinstance(value, str):
                info["label"] = value

    if version_code is not None:
        info["versionCode"] = (version_code_major << 32) | version_code
    if not info["packageName"]:
        raise ApkError("AndroidManifest.xml has no package name")
    if info["versionCode"] is None:
        raise ApkError("AndroidManifest.xml has no versionCode")
    return info


# --------------------------------------------------------------------------
# APK Signing Block
# --------------------------------------------------------------------------

def _find_eocd(data):
    # The End of Central Directory record may be followed by a comment of up to
    # 64 KiB, so scan backwards for its signature.
    max_comment = 0xFFFF
    start = max(0, len(data) - max_comment - 22)
    index = data.rfind(b"PK\x05\x06", start)
    if index < 0:
        raise ApkError("not a zip file: no end of central directory record")
    return index


def _length_prefixed(blob, limit=None):
    """Splits a concatenation of uint32-length-prefixed elements.

    `limit` stops after that many elements. It matters for scheme v3
    signed_data, which is `digests | certificates | minSdk | maxSdk |
    attributes`: the two SDK bounds are bare uint32s rather than
    length-prefixed, so reading past the second element would misparse them.
    """
    out = []
    pos = 0
    while pos + 4 <= len(blob):
        if limit is not None and len(out) >= limit:
            break
        (size,) = struct.unpack_from("<I", blob, pos)
        pos += 4
        if size > len(blob) - pos:
            raise ApkError("malformed length-prefixed sequence")
        out.append(blob[pos:pos + size])
        pos += size
    return out


def _signing_block_pairs(data):
    eocd = _find_eocd(data)
    (cd_offset,) = struct.unpack_from("<I", data, eocd + 16)
    if cd_offset < 24 or cd_offset > len(data):
        raise ApkError("central directory offset is out of range")
    if data[cd_offset - 16:cd_offset] != APK_SIG_BLOCK_MAGIC:
        return {}
    (footer_size,) = struct.unpack_from("<Q", data, cd_offset - 24)
    block_start = cd_offset - footer_size - 8
    if block_start < 0:
        raise ApkError("APK Signing Block extends past the start of the file")
    (header_size,) = struct.unpack_from("<Q", data, block_start)
    if header_size != footer_size:
        raise ApkError("APK Signing Block size fields disagree")

    pairs = {}
    pos = block_start + 8
    end = cd_offset - 24
    while pos + 12 <= end:
        (pair_len,) = struct.unpack_from("<Q", data, pos)
        pos += 8
        if pair_len < 4 or pair_len > end - pos:
            raise ApkError("malformed APK Signing Block entry")
        (pair_id,) = struct.unpack_from("<I", data, pos)
        pairs.setdefault(pair_id, data[pos + 4:pos + pair_len])
        pos += pair_len
    return pairs


def extract_certificates(data):
    """Returns (best_scheme_name, [certificate DER, ...]).

    Certificates from every scheme present are unioned. When an APK has had its
    signing key rotated, scheme v3 carries the current certificate and v2 the
    original one, and both are legitimate signers to accept.
    """
    pairs = _signing_block_pairs(data)
    best_scheme = None
    certs = []
    for pair_id, scheme in SIG_BLOCK_IDS:
        if pair_id not in pairs:
            continue
        if best_scheme is None:
            best_scheme = scheme
        for signer in _length_prefixed(_length_prefixed(pairs[pair_id])[0]):
            parts = _length_prefixed(signer, limit=1)
            if not parts:
                continue
            # signed_data starts with digests then certificates in v2 and v3 alike.
            signed_data = _length_prefixed(parts[0], limit=2)
            if len(signed_data) < 2:
                continue
            for cert in _length_prefixed(signed_data[1]):
                if cert not in certs:
                    certs.append(cert)
    return best_scheme, certs


# --------------------------------------------------------------------------

def read_apk(path):
    with open(path, "rb") as handle:
        data = handle.read()

    try:
        with zipfile.ZipFile(path) as archive:
            manifest = archive.read("AndroidManifest.xml")
    except KeyError:
        raise ApkError("no AndroidManifest.xml: not an APK")
    except zipfile.BadZipFile as exc:
        raise ApkError("not a valid zip archive: %s" % exc)

    info = parse_manifest(manifest)
    scheme, certs = extract_certificates(data)
    info["signatureScheme"] = scheme
    info["certDigests"] = [hashlib.sha256(cert).hexdigest() for cert in certs]
    return info


def _shell_output(info):
    """Emits `eval`-able assignments for the shell front-end."""
    import shlex

    fields = [
        ("APK_PACKAGE", info["packageName"]),
        ("APK_VERSION_CODE", info["versionCode"]),
        ("APK_VERSION_NAME", info["versionName"]),
        ("APK_MIN_SDK", info["minSdk"]),
        ("APK_TARGET_SDK", info["targetSdk"]),
        ("APK_SPLIT", info["split"]),
        ("APK_HAS_CODE", "true" if info["hasCode"] else "false"),
        ("APK_LABEL", info["label"]),
        ("APK_SIGNATURE_SCHEME", info["signatureScheme"]),
        ("APK_CERT_DIGESTS", " ".join(info["certDigests"])),
    ]
    return "\n".join(
        "%s=%s" % (name, shlex.quote("" if value is None else str(value)))
        for name, value in fields
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk")
    parser.add_argument("--shell", action="store_true",
                        help="print eval-able shell assignments instead of JSON")
    args = parser.parse_args()

    try:
        info = read_apk(args.apk)
    except ApkError as exc:
        print("error: %s: %s" % (args.apk, exc), file=sys.stderr)
        return 1

    if args.shell:
        print(_shell_output(info))
    else:
        print(json.dumps(info, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
