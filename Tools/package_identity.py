#!/usr/bin/env python3
"""Locally add a validated MFi identity to an unsigned IPA; never upload keys.

Requires Python's cryptography package. Run before re-signing the IPA.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import tempfile
import zipfile

NAMES = ("certificate.p7b", "leaf.cer", "private.x963")


def validate_identity(directory):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils
    from cryptography.hazmat.primitives.serialization import pkcs7

    files = {}
    for name in NAMES:
        path = Path(directory) / name
        if path.is_symlink() or not path.is_file() or not 1 <= path.stat().st_size <= 65_536:
            raise ValueError("Identity files must be complete regular files of at most 64 KiB")
        files[name] = path.read_bytes()
    raw = files["private.x963"]
    if len(raw) != 97 or raw[0] != 4:
        raise ValueError("Identity key must be a P-256 X9.63 private key")
    key = ec.derive_private_key(int.from_bytes(raw[65:], "big"), ec.SECP256R1())
    public = key.public_key().public_bytes(serialization.Encoding.X962,
                                          serialization.PublicFormat.UncompressedPoint)
    leaf = x509.load_der_x509_certificate(files["leaf.cer"])
    if raw[:65] != public or leaf.public_key().public_bytes(
            serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint) != public:
        raise ValueError("Identity certificate and private key do not match")
    if not any(cert.public_bytes(serialization.Encoding.DER) == files["leaf.cer"]
               for cert in pkcs7.load_der_pkcs7_certificates(files["certificate.p7b"])):
        raise ValueError("Identity certificate chain does not contain the leaf certificate")
    challenge = b"\x5a" * 32
    signature = key.sign(challenge, ec.ECDSA(utils.Prehashed(hashes.SHA256())))
    leaf.public_key().verify(signature, challenge, ec.ECDSA(utils.Prehashed(hashes.SHA256())))
    return files


def package(source, identity_directory, output):
    source, output = Path(source), Path(output)
    if source.resolve() == output.resolve() or output.exists():
        raise ValueError("Output must be a new file, separate from the source IPA")
    files = validate_identity(identity_directory)
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise ValueError("IPA has duplicate paths or invalid ZIP data")
        apps = {name.split("/")[1] for name in names
                if len(name.split("/")) == 3 and name.startswith("Payload/")
                and name.endswith(".app/Info.plist")}
        if len(apps) != 1:
            raise ValueError("IPA must contain exactly one main app")
        prefix = "Payload/" + apps.pop() + "/"
        if any(name.startswith(prefix + "_CodeSignature/") for name in names):
            raise ValueError("Use an unsigned IPA and re-sign after packaging")
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        executable = info["CFBundleExecutable"]
        if "/" in executable or executable in (".", ".."):
            raise ValueError("Invalid app executable path")
        binary = archive.read(prefix + executable)
        if len(binary) < 8 or struct.unpack("<II", binary[:8]) != (0xFEEDFACF, 0x100000C):
            raise ValueError("Expected a thin arm64 iOS app")
        for name, data in files.items():
            for resource in (prefix + name, prefix + "BundledIdentity/" + name):
                if resource in names and archive.read(resource) != data:
                    raise ValueError("IPA already contains a different identity; refusing to replace it")
        output.parent.mkdir(parents=True, exist_ok=True)
        # Keep the private-bearing temporary archive local and private until complete.
        with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".ipa", delete=False) as handle:
            temporary = Path(handle.name)
        try:
            with zipfile.ZipFile(temporary, "w") as target:
                for entry in archive.infolist():
                    target.writestr(entry, archive.read(entry.filename))
                for name, data in files.items():
                    path = prefix + name
                    if path in names:
                        continue
                    entry = zipfile.ZipInfo(path)
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    entry.external_attr = 0o100644 << 16
                    target.writestr(entry, data)
            with zipfile.ZipFile(temporary) as target:
                if target.testzip() is not None:
                    raise ValueError("Packaged IPA failed ZIP validation")
                if not all(target.read(name) == archive.read(name) for name in names):
                    raise ValueError("Original compiled app resources changed")
                if not all(target.read(prefix + name) == data for name, data in files.items()):
                    raise ValueError("Packaged IPA is missing identity resources")
            # Atomic no-clobber publication; never replace another package.
            os.link(temporary, output)
        finally:
            temporary.unlink(missing_ok=True)
    return {"ipa": str(output), "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"), "bytes": output.stat().st_size,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
            "identity": "certificate/key match, chain membership and ECDSA self-test passed",
            "archive": "ZIP CRC and original app entries verified; re-sign before installation"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--identity-directory", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = package(args.source, args.identity_directory, args.output)
    except Exception as error:
        # Do not echo cryptographic parser exceptions or any private material.
        parser.exit(1, "Packaging failed (" + type(error).__name__ + "). Check input files and unsigned IPA.\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
