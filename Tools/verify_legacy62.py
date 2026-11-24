#!/usr/bin/env python3
"""Verify the original 6.2 stack and the narrowly allowed IP discovery adapter."""
from hashlib import sha1, sha256
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
originals = root / 'Legacy62Original'
manifest = json.loads((originals / 'manifest.json').read_text(encoding='utf-8'))
for name, expected in manifest['original_files'].items():
    data = (originals / name).read_bytes().replace(b'\r\n', b'\n')
    assert sha256(data).hexdigest() == expected['sha256'], name
    assert sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == expected['git_blob'], name

def original_body(name):
    return '\n'.join(line for line in (originals / name).read_text(encoding='utf-8').splitlines()
                     if not line.startswith('import ')).strip() + '\n'

text = (root / 'App/Zeeho62Legacy.swift').read_text(encoding='utf-8')
blocks = {}
for name, expected in manifest['embedded_blocks'].items():
    start, end = '    // BEGIN ORIGINAL62 ' + name + '\n', '    // END ORIGINAL62 ' + name
    assert text.count(start) == 1 and text.count(end) == 1
    value = text.split(start, 1)[1].split(end, 1)[0]
    value = ''.join(line[4:] + '\n' for line in value.splitlines())
    assert sha256(value.encode('utf-8')).hexdigest() == expected, name
    blocks[name] = value

assert blocks['output'] == original_body('ZeehoOutput.swift'), '6.2 output changed'
protocol = original_body('TailingProtocol.swift')
assert blocks['protocol'] == protocol[protocol.index('enum TailingProtocol'):protocol.index('extension Data')].strip() + '\n'
assert blocks['errors'] == protocol[protocol.index('enum TailingError'):].strip() + '\n'
connection = blocks['connection'].replace('private var targetIP: String', 'private let targetIP: String')
connection, count = re.subn(r'        var discoveredSocket: TailingSocket\?\n        if targetIP.isEmpty \{\n.*?\n        \}\n', '', connection, count=1, flags=re.S)
assert count == 1
connection, count = re.subn(r'        let announcement: TailingSocket\n        if let discoveredSocket.*?        defer \{ announcement.close\(\) \}\n',
    '        let announcement = try tracked(TailingSocket.create())\n        defer { announcement.close() }\n        try announcement.connect(localIP: localIP, remoteIP: targetIP, port: ports.announcement)\n', connection, count=1, flags=re.S)
assert count == 1
connection = connection.replace('        UserDefaults.standard.set(targetIP, forKey: TailingDiscovery.savedAddressKey)\n', '')
assert connection == original_body('TailingConnection.swift'), '6.2 negotiation changed beyond discovery adapter'
for name in manifest['shared_original_files']:
    assert (root / 'App' / name).read_text(encoding='utf-8') == (originals / name).read_text(encoding='utf-8'), name
helpers = protocol[protocol.index('extension Data'):protocol.index('enum TailingError')].strip()
assert helpers in (root / 'App/TailingProtocol.swift').read_text(encoding='utf-8')
native = (root / 'App/NativeReceiver.swift').read_text(encoding='utf-8')
assert 'private let zeeho62 = Zeeho62Legacy.ZeehoOutput()' in native
assert 'self.zeeho62.start(' in native and 'self.zeeho62.append(' in native and 'zeeho62.stop()' in native
settings = (root / 'App/ReceiverViewController.swift').read_text(encoding='utf-8')
cases = re.search(r'private enum HeadUnitOutput: Int \{.*?\bcase ([^\n]+)', settings, re.S).group(1)
assert [name.strip() for name in cases.split(',')] == [
    'browser', 'carLife', 'airPlay', 'tailing', 'ninebot', 'zeeho', 'ninebotSeven', 'ninebot43', 'zeehoSEPlus'
], 'persisted output IDs changed'
print('PASS: original 6.2 output and wire codec unchanged; original negotiation restored with IP-discovery-only changes; raw snapshots and shared socket/identity verified')
print('PASS: upstream output IDs 0–7 preserved; SE+ appended as ID 8')
