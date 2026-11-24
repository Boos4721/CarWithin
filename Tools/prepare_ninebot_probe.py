#!/usr/bin/env python3
"""Prepare a new unsigned Ninebot IPA for the observation companion; never signs or decrypts."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zipfile

PROBE_PATH = "Frameworks/CarWithinNinebotProbe.dylib"
LOAD_PATH = "@executable_path/" + PROBE_PATH


def load_commands(binary):
    if len(binary) < 32 or struct.unpack_from("<II", binary) != (0xFEEDFACF, 0x100000C):
        raise ValueError("Expected a thin arm64 Mach-O; fat/encrypted archives need separate preparation")
    count, size = struct.unpack_from("<II", binary, 16)
    end = 32 + size
    if count > 4096 or end > len(binary):
        raise ValueError("Invalid Mach-O load command table")
    cursor = 32
    commands = []
    for _ in range(count):
        if cursor + 8 > end:
            raise ValueError("Truncated load command")
        cmd, length = struct.unpack_from("<II", binary, cursor)
        if length < 8 or length % 8 or cursor + length > end:
            raise ValueError("Invalid load command length")
        commands.append((cmd, cursor, length))
        cursor += length
    if cursor != end:
        raise ValueError("Load command size mismatch")
    return commands, end


def insert_companion(binary):
    commands, end = load_commands(binary)
    first_section = len(binary)
    for cmd, offset, length in commands:
        if cmd == 0x2C:  # LC_ENCRYPTION_INFO_64
            if length < 24 or struct.unpack_from("<I", binary, offset + 16)[0]:
                raise ValueError("App executable is encrypted; this tool does not decrypt IPA files")
        if cmd in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            if length < 24:
                raise ValueError("Invalid dylib command")
            name_offset = struct.unpack_from("<I", binary, offset + 8)[0]
            if not 24 <= name_offset < length:
                raise ValueError("Invalid dylib name offset")
            name = binary[offset + name_offset:offset + length].split(b"\0", 1)[0]
            if name == LOAD_PATH.encode():
                raise ValueError("Companion already loaded; use a clean source IPA")
        if cmd == 0x19:  # LC_SEGMENT_64
            if length < 72:
                raise ValueError("Invalid segment")
            nsects = struct.unpack_from("<I", binary, offset + 64)[0]
            if 72 + nsects * 80 > length:
                raise ValueError("Truncated sections")
            fileoff, filesize = struct.unpack_from("<QQ", binary, offset + 40)
            if fileoff > 0 and filesize > 0:
                first_section = min(first_section, fileoff)
            for index in range(nsects):
                section = offset + 72 + 80 * index
                section_type = struct.unpack_from("<I", binary, section + 64)[0] & 0xFF
                data_offset = struct.unpack_from("<I", binary, section + 48)[0]
                if data_offset and section_type not in (1, 12, 18):  # zero-fill has no file bytes
                    first_section = min(first_section, data_offset)
    payload = LOAD_PATH.encode() + b"\0"
    length = (24 + len(payload) + 7) & ~7
    if first_section < end + length or any(binary[end:end + length]):
        raise ValueError("Insufficient empty Mach-O header padding; refusing to move executable data")
    command = struct.pack("<IIIIII", 0xC, length, 24, 0, 0x10000, 0x10000)
    command = (command + payload).ljust(length, b"\0")
    output = bytearray(binary)
    output[end:end + length] = command
    struct.pack_into("<II", output, 16, len(commands) + 1, end - 32 + length)
    load_commands(output)
    return bytes(output)


def prepare(ipa_path, probe_path, output_path):
    ipa_path, probe_path, output_path = map(Path, (ipa_path, probe_path, output_path))
    if output_path.resolve() in (ipa_path.resolve(), probe_path.resolve()) or output_path.exists():
        raise ValueError("Output must be a new file; source files are never overwritten")
    probe = probe_path.read_bytes()
    load_commands(probe)
    if struct.unpack_from("<I", probe, 12)[0] != 6:
        raise ValueError("Companion must be an arm64 dynamic library")
    with zipfile.ZipFile(ipa_path) as source:
        names = source.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate ZIP entries are not supported")
        plists = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if len(plists) != 1:
            raise ValueError("Expected exactly one Payload app")
        info_name = plists[0]
        if source.getinfo(info_name).file_size > 1024 * 1024:
            raise ValueError("Info.plist too large")
        info = plistlib.loads(source.read(info_name))
        identity = " ".join(str(info.get(key, "")) for key in
                            ("CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"))
        if "ninebot" not in identity.lower() and "九号" not in identity:
            raise ValueError("Archive does not identify itself as Ninebot")
        executable_name = info.get("CFBundleExecutable", "")
        if not executable_name or "/" in executable_name or executable_name in (".", ".."):
            raise ValueError("Invalid executable name")
        prefix = info_name.removesuffix("Info.plist")
        executable = prefix + executable_name
        if source.getinfo(executable).file_size > 512 * 1024 * 1024:
            raise ValueError("Executable too large")
        if sum(entry.file_size for entry in source.infolist()) > 2 * 1024 ** 3:
            raise ValueError("Archive too large")
        if prefix + PROBE_PATH in names:
            raise ValueError("Companion already present; use a clean source IPA")
        # Diagnostic-only target. Class and signature checks in the companion remain authoritative.
        if not str(info.get("CFBundleShortVersionString", "")).startswith("6."):
            raise ValueError("Expected Ninebot 6.x; inspect the source IPA")
        modified = insert_companion(source.read(executable))
        types = info.setdefault("CFBundleURLTypes", [])
        if not isinstance(types, list):
            raise ValueError("Invalid URL types")
        if any("cw-ninebot-probe" in item.get("CFBundleURLSchemes", []) for item in types):
            raise ValueError("Helper URL scheme already registered")
        types.append({"CFBundleURLName": "CarWithinNinebotProbe", "CFBundleURLSchemes": ["cw-ninebot-probe"]})
        patched_info = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
        with zipfile.ZipFile(output_path, "x", compression=zipfile.ZIP_DEFLATED) as target:
            for entry in source.infolist():
                if "/_CodeSignature/" in entry.filename:
                    continue
                data = modified if entry.filename == executable else patched_info if entry.filename == info_name else source.read(entry)
                target.writestr(entry, data)
            target.writestr(prefix + PROBE_PATH, probe)
    with zipfile.ZipFile(output_path) as check:
        if check.testzip() is not None:
            raise ValueError("Output CRC check failed")
    return {"app_version": info.get("CFBundleShortVersionString"), "app_build": info.get("CFBundleVersion"),
            "output": str(output_path), "sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
            "status": "Unsigned observation build; re-sign all code before installation",
            "activation": "Not implemented; manual official projection required for observation"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, help="Your prepared, unencrypted Ninebot 6.x IPA")
    parser.add_argument("--probe", required=True, help="CarWithinNinebotProbe.dylib")
    parser.add_argument("--output", required=True, help="New unsigned IPA path")
    args = parser.parse_args()
    try:
        result = prepare(args.ipa, args.probe, args.output)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, str(error) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
