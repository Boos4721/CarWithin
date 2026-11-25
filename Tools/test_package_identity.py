#!/usr/bin/env python3
"""Packaging regressions use newly generated test keys, never a real MFi identity."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import pkcs7
from cryptography.x509.oid import NameOID
from package_identity import NAMES, package


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.identity = self.root / "identity"
        self.identity.mkdir()
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Packaging test only")])
        now = datetime.now(timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(days=1))
                .sign(key, hashes.SHA256()))
        chain = (pkcs7.PKCS7SignatureBuilder().set_data(b"test")
                 .add_signer(cert, key, hashes.SHA256())
                 .sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary]))
        raw = key.public_key().public_bytes(serialization.Encoding.X962,
                                           serialization.PublicFormat.UncompressedPoint)
        raw += key.private_numbers().private_value.to_bytes(32, "big")
        for filename, data in zip(NAMES, [chain, cert.public_bytes(serialization.Encoding.DER), raw]):
            (self.identity / filename).write_bytes(data)
        self.source = self.root / "source.ipa"
        self.output = self.root / "output.ipa"
        self.prefix = "Payload/Test.app/"
        self.make_source()

    def make_source(self, extras=None):
        with zipfile.ZipFile(self.source, "w") as archive:
            archive.writestr(self.prefix + "Info.plist", plistlib.dumps({
                "CFBundleExecutable": "Test", "CFBundleShortVersionString": "1.0.4", "CFBundleVersion": "31"}))
            entry = zipfile.ZipInfo(self.prefix + "Test")
            entry.external_attr = 0o100755 << 16
            archive.writestr(entry, struct.pack("<II", 0xFEEDFACF, 0x100000C) + b"test fixture only")
            archive.writestr(self.prefix + "asset.bin", b"unchanged")
            for filename, data in (extras or {}).items():
                archive.writestr(filename, data)

    def test_complete_package_preserves_original_and_adds_matching_identity(self):
        original = self.source.read_bytes()
        report = package(self.source, self.identity, self.output)
        self.assertEqual(report["build"], "31")
        self.assertEqual(self.source.read_bytes(), original)
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(self.output) as target:
            self.assertIsNone(target.testzip())
            for entry in source.infolist():
                self.assertEqual(source.read(entry.filename), target.read(entry.filename))
                self.assertEqual(entry.external_attr, target.getinfo(entry.filename).external_attr)
            for filename in NAMES:
                self.assertEqual(target.read(self.prefix + filename), (self.identity / filename).read_bytes())
        # An update with the same resources must not create duplicate ZIP entries.
        second = self.root / "second.ipa"
        package(self.output, self.identity, second)
        with zipfile.ZipFile(second) as archive:
            self.assertEqual(len(archive.namelist()), len(set(archive.namelist())))

    def test_partial_or_mismatched_identity_never_produces_output(self):
        leaf = self.identity / "leaf.cer"
        saved = leaf.read_bytes()
        leaf.unlink()
        with self.assertRaises(ValueError):
            package(self.source, self.identity, self.output)
        self.assertFalse(self.output.exists())
        leaf.write_bytes(saved)
        key = self.identity / "private.x963"
        raw = bytearray(key.read_bytes())
        raw[-1] ^= 1
        key.write_bytes(raw)
        with self.assertRaises(ValueError):
            package(self.source, self.identity, self.output)
        self.assertFalse(self.output.exists())

    def test_does_not_replace_existing_output_or_another_identity(self):
        self.output.write_bytes(b"keep existing file")
        with self.assertRaises(ValueError):
            package(self.source, self.identity, self.output)
        self.assertEqual(self.output.read_bytes(), b"keep existing file")
        self.output.unlink()
        self.make_source({self.prefix + "certificate.p7b": b"different identity"})
        with self.assertRaises(ValueError):
            package(self.source, self.identity, self.output)
        self.assertFalse(self.output.exists())

    def test_rejects_signed_or_ambiguous_app_archives(self):
        for extras in [{self.prefix + "_CodeSignature/CodeResources": b"signed"},
                       {"Payload/Other.app/Info.plist": b"other app"}]:
            self.make_source(extras)
            with self.assertRaises(ValueError):
                package(self.source, self.identity, self.output)
            self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
