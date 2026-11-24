#!/usr/bin/env python3
import plistlib
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
from prepare_ninebot_probe import insert_companion, load_commands, prepare, LOAD_PATH


def macho(encrypted=False, padding=True, dylib=False):
    # Synthetic __TEXT section, encrypted flag and code-signature command. Never executable code.
    segment = bytearray(152)
    struct.pack_into('<II', segment, 0, 0x19, 152)
    struct.pack_into('<I', segment, 64, 1)
    struct.pack_into('<I', segment, 72 + 48, 512)
    encryption = struct.pack('<IIIIII', 0x2C, 24, 512, 16, int(encrypted), 0)
    signature = struct.pack('<IIII', 0x1D, 16, 600, 8)
    commands = bytes(segment) + encryption + signature
    header = struct.pack('<IIIIIIII', 0xFEEDFACF, 0x100000C, 0, 6 if dylib else 2, 3, len(commands), 0, 0)
    result = bytearray((header + commands).ljust(608, b'\0'))
    result[512:528] = b'fake-section-1234'
    if not padding: result[len(header + commands)] = 1
    return bytes(result)


class PrepareTests(unittest.TestCase):
    def test_inserts_command_without_moving_sections_or_signature_data(self):
        original = macho()
        patched = insert_companion(original)
        commands, _ = load_commands(patched)
        self.assertEqual(len(commands), 4)
        self.assertIn(LOAD_PATH.encode(), patched)
        self.assertEqual(patched[512:], original[512:])
        self.assertEqual(len(patched), len(original))
        with self.assertRaises(ValueError): insert_companion(patched)

    def test_refuses_encryption_nonempty_padding_and_unsupported_headers(self):
        for binary in [macho(encrypted=True), macho(padding=False), b'not-macho']:
            with self.subTest(binary=binary[:8]), self.assertRaises(ValueError): insert_companion(binary)

    def test_archive_preserves_identity_and_resources_registers_only_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa, probe, output = root/'source.ipa', root/'probe.dylib', root/'output.ipa'
            probe.write_bytes(macho(dylib=True))
            info = {'CFBundleIdentifier': 'cn.ninebot.segway', 'CFBundleExecutable': 'Ninebot',
                    'CFBundleShortVersionString': '6.10.13', 'CFBundleVersion': 'test',
                    'CFBundleURLTypes': [{'CFBundleURLSchemes': ['ninebot-original']}]}
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Ninebot.app/Info.plist', plistlib.dumps(info))
                archive.writestr('Payload/Ninebot.app/Ninebot', macho())
                archive.writestr('Payload/Ninebot.app/resource.bin', b'unchanged-resource')
                archive.writestr('Payload/Ninebot.app/_CodeSignature/CodeResources', b'old')
            before = ipa.read_bytes()
            report = prepare(ipa, probe, output)
            self.assertEqual(ipa.read_bytes(), before)
            self.assertEqual(report['app_version'], '6.10.13')
            with zipfile.ZipFile(output) as archive:
                patched = plistlib.loads(archive.read('Payload/Ninebot.app/Info.plist'))
                self.assertEqual(patched['CFBundleIdentifier'], info['CFBundleIdentifier'])
                self.assertEqual(patched['CFBundleURLTypes'][0], info['CFBundleURLTypes'][0])
                self.assertEqual(patched['CFBundleURLTypes'][-1]['CFBundleURLSchemes'], ['cw-ninebot-probe'])
                self.assertEqual(archive.read('Payload/Ninebot.app/resource.bin'), b'unchanged-resource')
                self.assertNotIn('Payload/Ninebot.app/_CodeSignature/CodeResources', archive.namelist())
                self.assertEqual(archive.read('Payload/Ninebot.app/Frameworks/CarWithinNinebotProbe.dylib'), probe.read_bytes())
            with self.assertRaises(ValueError): prepare(ipa, probe, output)
            with self.assertRaises(ValueError): prepare(ipa, probe, ipa)


if __name__ == '__main__': unittest.main()
