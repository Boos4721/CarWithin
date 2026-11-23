// 春风 MotoPlay 仪表 UDP 通道：一帧 H.264 访问单元打成一个 RTP 时间戳。
import Darwin
import Foundation

/// Sends H.264 access units over UDP.
///
/// `.rtp` 按 RFC 6184 打包（载荷类型 96，超过 MTU 用 FU-A 分片），这是大多数车机/仪表
/// 视频端口期望的形态；`.rawAnnexB` 不加头，直接把 Annex-B 字节切块发出，只用于电脑自测：
/// `ffplay -f h264 udp://0.0.0.0:21000`。
final class CfmotoUDPChannel {
    enum Mode { case rtp, rawAnnexB }

    private let fd: Int32
    private let mode: Mode
    private let fps: Int
    private let payloadLimit = 1400
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private let ssrc: UInt32
    private let closeLock = NSLock()
    private var closed = false

    init(localIP: String, targetIP: String, port: UInt16, fps: Int, mode: Mode) throws {
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        guard inet_pton(AF_INET, localIP, &local.sin_addr) == 1 else {
            throw ConfigurationError("春风的本地地址无效：\(localIP)")
        }
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { throw TailingError.system("创建春风 UDP 套接字", errno) }
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw TailingError.system("绑定春风 UDP 地址", code)
        }
        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = port.bigEndian
        guard inet_pton(AF_INET, targetIP, &remote.sin_addr) == 1 else {
            Darwin.close(socketFD)
            throw ConfigurationError("春风仪表地址无效：\(targetIP)")
        }
        let connected = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw TailingError.system("连接春风仪表 UDP 端口", code)
        }
        self.fd = socketFD
        self.mode = mode
        self.fps = max(1, fps)
        self.ssrc = UInt32.random(in: 1...UInt32.max)
    }

    deinit { close() }

    func send(accessUnit: Data, keyframe: Bool) throws {
        switch mode {
        case .rtp:
            let units = try AnnexB.units(in: accessUnit)
            guard !units.isEmpty else { return }
            timestamp &+= UInt32(90_000 / fps)
            try sendRTP(units)
        case .rawAnnexB:
            try sendRaw(accessUnit)
        }
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    private func sendRTP(_ units: [Data]) throws {
        for (index, unit) in units.enumerated() {
            guard let first = unit.first else { continue }
            let lastUnit = index == units.count - 1
            if unit.count <= payloadLimit {
                var packet = rtpHeader(marker: lastUnit)
                packet.append(unit)
                try write(packet)
                continue
            }
            // FU-A：指示字节沿用原 NAL 的 F/NRI，后续分片带起始/结束位。
            let indicator = (first & 0xE0) | 28
            let type = first & 0x1F
            var offset = 1
            while offset < unit.count {
                let size = min(payloadLimit - 2, unit.count - offset)
                let ends = offset + size >= unit.count
                var packet = rtpHeader(marker: lastUnit && ends)
                packet.append(indicator)
                packet.append((offset == 1 ? 0x80 : 0) | (ends ? 0x40 : 0) | type)
                packet.append(contentsOf: unit[offset..<(offset + size)])
                try write(packet)
                offset += size
            }
        }
    }

    private func sendRaw(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let size = min(payloadLimit, data.count - offset)
            try write(data[offset..<(offset + size)])
            offset += size
        }
    }

    private func rtpHeader(marker: Bool) -> Data {
        var header = Data(capacity: 12)
        header.append(0x80)
        header.append((marker ? 0x80 : 0x00) | 96)
        header.append(UInt8(truncatingIfNeeded: sequence >> 8))
        header.append(UInt8(truncatingIfNeeded: sequence))
        sequence &+= 1
        header.append(UInt8(truncatingIfNeeded: timestamp >> 24))
        header.append(UInt8(truncatingIfNeeded: timestamp >> 16))
        header.append(UInt8(truncatingIfNeeded: timestamp >> 8))
        header.append(UInt8(truncatingIfNeeded: timestamp))
        header.append(UInt8(truncatingIfNeeded: ssrc >> 24))
        header.append(UInt8(truncatingIfNeeded: ssrc >> 16))
        header.append(UInt8(truncatingIfNeeded: ssrc >> 8))
        header.append(UInt8(truncatingIfNeeded: ssrc))
        return header
    }

    private func write(_ data: Data) throws {
        let result = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return Darwin.send(fd, base, buffer.count, 0)
        }
        if result < 0 { throw TailingError.system("发送春风 UDP 画面", errno) }
    }
}
