// DL wire layout adapted from NinebotEnhance 2eb54bb (Apache-2.0).
// Swift session, validation and telemetry mapping are modified for CarWithin.
// See App/DL-BMS-LICENSE.txt. No parameter or protection control commands.
import Foundation
#if SWIFT_PACKAGE
import CTDSCarKitCrypto
#endif

/// A new ephemeral key for each BLE channel. All buffers and requests are bounded.
final class BMSDLSession {
    enum Failure: Error { case crypto }
    struct Request { let function: UInt8; let serial: UInt16; let sentAt: Double }
    private var privateKey: [UInt8] = []
    private var publicKey: [UInt8] = []
    private var shared: [UInt8] = []
    private var serial: UInt16 = 0
    private var pending: Request?
    private var buffer: [UInt8] = []
    private var issued: Data?
    private var nextAt = 0.0
    private(set) var error: String?
    private(set) var halted = false
    var isAuthenticated: Bool { shared.count == 32 }
    static let maximumFrameBytes = 157 // 13-byte header + 142-byte full FC17 + checksum.
    static let maximumWireBytes = 160

    init() {}
    deinit {
        _ = privateKey.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        _ = shared.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }
    static func keyPair(privateKey supplied: [UInt8]? = nil) throws -> (privateKey: [UInt8], publicKey: [UInt8]) {
        var secret = supplied ?? [UInt8](repeating: 0, count: 32)
        guard secret.count == 32 else { throw Failure.crypto }
        var pub = [UInt8](repeating: 0, count: 64)
        let status = supplied == nil ? tds_dl_make_key(&secret, &pub) : tds_dl_public_key(secret, &pub)
        guard status == 1 else { throw Failure.crypto }
        return (secret, pub)
    }
    static func secret(privateKey: [UInt8], peer: [UInt8]) throws -> [UInt8] {
        guard privateKey.count == 32, peer.count == 64 else { throw Failure.crypto }
        var result = [UInt8](repeating: 0, count: 32)
        guard tds_dl_shared_secret(privateKey, peer, &result) == 1,
              result.contains(where: { $0 != 0 }) else { throw Failure.crypto }
        return result
    }
    static func crypt(_ bytes: [UInt8], shared: [UInt8], encrypt: Bool) throws -> [UInt8] {
        guard shared.count == 32, !bytes.isEmpty, bytes.count <= maximumWireBytes else { throw Failure.crypto }
        var input = bytes
        if encrypt { input += [UInt8](repeating: 0, count: (16 - input.count % 16) % 16) }
        guard input.count % 16 == 0 else { throw Failure.crypto }
        var output = [UInt8](repeating: 0, count: input.count)
        let key = Array(shared.prefix(16)), iv = Array(shared.suffix(16))
        guard tds_dl_aes_cbc(encrypt ? 1 : 0, key, iv, input, input.count, &output) == 0 else { throw Failure.crypto }
        return output
    }
    static func frame(function: UInt8, content: [UInt8], serial: UInt16, response: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = response ? [0x5a, 0xa5, 0, 0x40] : [0xa5, 0x5a, 0, 0x40]
        func le(_ n: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8)] }
        bytes += [function] + le(Int(serial)) + [1, 0, 1, 0] + le(content.count)
        bytes += !response && content.count <= 4 ? Array(content.reversed()) : content
        bytes += le(Int(bytes.reduce(UInt16(0)) { $0 &+ UInt16($1) }))
        return bytes
    }
    /// Only a well-formed ephemeral-public-key request is statically recognizable.
    static func permitsHandshake(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count == 79, b[4] == 0, b[0..<4] == [0xa5, 0x5a, 0, 0x40] else { return false }
        let pub = Array(b[13..<77])
        return tds_dl_valid_public_key(pub) == 1 && b == frame(function: 0, content: pub, serial: UInt16(BMSBytes(b).le16(5)))
    }
    /// Validate the exact issued frame again at the BLE boundary, including encrypted FC17.
    func permits(_ data: Data) -> Bool {
        guard data == issued, let pending else { return false }
        if pending.function == 0 { return Self.permitsHandshake(data) }
        guard pending.function == 0x17, isAuthenticated,
              let plain = try? Self.crypt([UInt8](data), shared: shared, encrypt: false) else { return false }
        let request = Self.frame(function: 0x17, content: [], serial: pending.serial)
        return plain == request + [UInt8](repeating: 0, count: (16 - request.count % 16) % 16)
    }
    func nextRequest(now: Double) -> Data? {
        guard !halted else { return nil }
        if let pending {
            guard now - pending.sentAt >= 3 else { return nil }
            self.pending = nil; issued = nil; buffer.removeAll()
            error = isAuthenticated ? "DL 实时读取超时" : "DL 本地握手超时"
        }
        guard now >= nextAt else { return nil }
        do {
            if privateKey.isEmpty {
                let pair = try Self.keyPair(); privateKey = pair.privateKey; publicKey = pair.publicKey
            }
            serial &+= 1
            let fc: UInt8 = isAuthenticated ? 0x17 : 0
            var bytes = Self.frame(function: fc, content: fc == 0 ? publicKey : [], serial: serial)
            if fc != 0 { bytes = try Self.crypt(bytes, shared: shared, encrypt: true) }
            pending = Request(function: fc, serial: serial, sentAt: now)
            issued = Data(bytes); buffer.removeAll(keepingCapacity: true)
            return issued
        } catch {
            self.error = "DL 加密会话初始化失败，请重试连接"; halted = true; return nil
        }
    }
    func append(_ data: Data, now: Double) -> [ANTBMSReading] {
        guard !halted, let request = pending, now >= request.sentAt, now - request.sentAt < 3 else { return [] }
        var readings: [ANTBMSReading] = []
        // Drain complete frames before reading the next byte; handles fragmentation and coalescing.
        for byte in data.prefix(4096) {
            if buffer.count >= Self.maximumWireBytes { buffer.removeAll(); error = "DL 回复超出长度上限" }
            buffer.append(byte)
            while let frame = takeFrame() {
                let d = BMSBytes(frame)
                guard let current = pending, frame[4] == current.function, d.le16(5) == Int(current.serial),
                      d.le16(7) == 1, d.le16(9) == 1 else { continue }
                let content = Array(frame[13..<(frame.count - 2)])
                if current.function == 0 {
                    do {
                        shared = try Self.secret(privateKey: privateKey, peer: content)
                        _ = privateKey.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                        pending = nil; issued = nil; error = nil; nextAt = now
                    } catch { self.error = "DL 握手公钥无效，等待有效回复" }
                } else if let value = Self.decode(content) {
                    readings.append(value); pending = nil; issued = nil; error = nil; nextAt = now + 1
                } else { error = "DL 实时数据布局或范围不匹配" }
            }
        }
        return readings
    }
    private func takeFrame() -> [UInt8]? {
        let encrypted = isAuthenticated
        if encrypted && (buffer.count < 16 || buffer.count % 16 != 0) { return nil }
        guard let plain = encrypted ? (try? Self.crypt(buffer, shared: shared, encrypt: false)) : buffer else {
            buffer.removeAll(); error = "DL 回复解密失败"; return nil
        }
        guard plain.count >= 4 else { return nil }
        guard plain[0..<4] == [0x5a, 0xa5, 0, 0x40] else {
            if encrypted { buffer.removeFirst(16) } else { buffer.removeFirst() }
            return takeFrame()
        }
        guard plain.count >= 13 else { return nil }
        let length = 15 + BMSBytes(plain).le16(11)
        guard length <= Self.maximumFrameBytes else {
            buffer.removeAll(); error = "DL 回复长度无效"; return nil
        }
        let wireLength = encrypted ? (length + 15) / 16 * 16 : length
        guard plain.count >= wireLength else { return nil }
        let frame = Array(plain.prefix(length))
        buffer.removeFirst(wireLength)
        guard BMSBytes(frame).le16(length - 2) == Int(frame.dropLast(2).reduce(UInt16(0)) { $0 &+ UInt16($1) }),
              !encrypted || plain[length..<wireLength].allSatisfy({ $0 == 0 }) else {
            error = "DL 回复校验失败"; return nil
        }
        return frame
    }
    static func decode(_ bytes: [UInt8]) -> ANTBMSReading? {
        guard (46...142).contains(bytes.count) else { return nil }
        // The full layout prefixes the same basic block with a fixed 32-byte name.
        let namePrefix = bytes.prefix(32)
        let named = bytes.count >= 78 && (32...126).contains(bytes[0]) && namePrefix.allSatisfy { $0 == 0 || (32...126).contains($0) }
        let full = bytes.count == 142 || named
        let offset = full ? 32 : 0, base = full ? 78 : 46
        guard bytes.count >= base else { return nil }
        let d = BMSBytes(bytes), cells = d.u8(offset + 1), sensors = d.u8(offset + 20)
        guard (1...32).contains(cells), sensors <= 9, bytes.count >= base + cells * 2 else { return nil }
        let voltage = Double(d.le16(offset + 10)) / 10
        guard voltage <= 650 else { return nil }
        var v = BMSValues()
        v.voltage = voltage; v.current = Double(d.li16(offset + 12)) / 10; v.power = d.li32(offset + 14)
        let soc = d.le16(offset + 18); v.soc = soc <= 100 ? soc : nil
        let capacity = d.le32(offset + 2), remaining = d.le32(offset + 6)
        v.capacity = capacity != UInt32.max ? Double(capacity) / 10 : nil
        v.remaining = remaining != UInt32.max ? Double(remaining) / 10 : nil
        // DL's native convention is discharge-positive; the common state label uses ANT codes.
        v.state = (v.current ?? 0) < -0.05 ? 2 : (v.current ?? 0) > 0.05 ? 4 : 1
        v.cells = (0..<cells).map { index -> Double? in
            let raw = d.le16(base + index * 2)
            guard raw != 0, raw != 0xffff else { return nil }
            let mv = raw > 10000 ? (Double(raw) / 13.4).rounded() : Double(raw)
            return (500...6000).contains(mv) ? mv / 1000 : nil
        }
        v.temperatures = (0..<sensors).map { index -> Double? in
            let raw = Int(Int8(bitPattern: bytes[offset + 21 + index]))
            return (-50...120).contains(raw) ? Double(raw) : nil
        }
        v.details = ["协议": full ? "DL FC17 完整" : "DL FC17 精简", "串数": String(cells),
                     "电流方向": "正值放电、负值充电", "MOS 原始状态": String(format: "0x%02X", bytes[offset])]
        if full {
            let name = d.text(0, 32); if !name.isEmpty { v.details["设备名称"] = name }
            let delta = d.le16(68); if delta != 0xffff, delta <= 5500 { v.delta = Double(delta) / 1000 }
            let cycles = d.le32(74); if cycles != UInt32.max { v.details["循环次数"] = String(cycles) }
            let cycleAh = d.le32(70); if cycleAh != UInt32.max { v.details["循环容量"] = String(format: "%.1f Ah", Double(cycleAh) / 10) }
        }
        return v.reading(.dl)
    }
}
