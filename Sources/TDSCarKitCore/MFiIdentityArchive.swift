import Compression
import Foundation

/// The three files this project's accessory identity loader expects. Extraction
/// alone does not establish Apple trust; the caller must validate the identity.
public struct MFiIdentityFiles {
    public static let names = Set(["certificate.p7b", "leaf.cer", "private.x963"])
    public let certificateChain: Data
    public let leafCertificate: Data
    public var privateKey: Data

    public init(files: [String: Data]) throws {
        guard Set(files.keys) == Self.names,
              files.values.allSatisfy({ !$0.isEmpty && $0.count <= 65_536 }) else {
            throw MFiIdentityArchive.Failure.missingFiles
        }
        certificateChain = files["certificate.p7b"]!
        leafCertificate = files["leaf.cer"]!
        privateKey = files["private.x963"]!
    }

    /// Read one complete set, never combining files from different locations.
    /// Xcode can flatten resources or preserve the BundledIdentity folder.
    public static func bundled(in resourceDirectory: URL) throws -> Self {
        for directory in [resourceDirectory,
                          resourceDirectory.appendingPathComponent("BundledIdentity", isDirectory: true)] {
            let urls = names.map { directory.appendingPathComponent($0) }
            guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            var files: [String: Data] = [:]
            for url in urls {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, (1...65_536).contains(size) else {
                    throw MFiIdentityArchive.Failure.invalidEntry
                }
                files[url.lastPathComponent] = try Data(contentsOf: url, options: [.uncached])
            }
            return try Self(files: files)
        }
        throw MFiIdentityArchive.Failure.missingFiles
    }
}

/// Reads only the expected identity resources from one app inside a user-chosen
/// IPA. No paths from the archive are written to disk, and output is bounded.
public enum MFiIdentityArchive {
    public static let maximumArchiveSize = 128 * 1024 * 1024

    public enum Failure: LocalizedError {
        case invalidArchive, unsupportedArchive, missingFiles, ambiguousIdentity, invalidEntry
        public var errorDescription: String? {
            switch self {
            case .invalidArchive: return "不是完整、有效的 IPA/ZIP 安装包。"
            case .unsupportedArchive: return "此安装包使用不支持的 ZIP 格式或加密方式。"
            case .missingFiles: return "未找到完整身份材料。请选择原来可用的 IPA，或同时选择 certificate.p7b、leaf.cer 和 private.x963。"
            case .ambiguousIdentity: return "安装包包含重复或多组身份材料，无法确定要导入哪一组。"
            case .invalidEntry: return "身份文件大小、路径或校验值不正确，未导入。"
            }
        }
    }

    private struct Entry {
        let name: String
        let method: Int
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let offset: Int
    }

    public static func extract(from data: Data) throws -> MFiIdentityFiles {
        guard (22...maximumArchiveSize).contains(data.count) else { throw Failure.invalidArchive }
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i + $1]) << ($1 * 8) }
        }
        let first = max(0, bytes.count - 22 - 65_535)
        guard let end = stride(from: bytes.count - 22, through: first, by: -1).first(where: {
            u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == bytes.count
        }) else { throw Failure.invalidArchive }
        guard u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == u16(end + 10),
              u16(end + 10) < 20_000, u32(end + 12) != .max, u32(end + 16) != .max else {
            throw Failure.unsupportedArchive
        }
        let centralStart = Int(u32(end + 16)), centralSize = Int(u32(end + 12))
        guard centralSize <= 16 * 1024 * 1024, centralStart + centralSize <= end else { throw Failure.invalidArchive }
        let centralEnd = centralStart + centralSize
        var cursor = centralStart
        var groups: [String: [String: Entry]] = [:]
        for _ in 0..<u16(end + 10) {
            guard cursor + 46 <= centralEnd, u32(cursor) == 0x02014b50 else { throw Failure.invalidArchive }
            let nameSize = u16(cursor + 28), extraSize = u16(cursor + 30), commentSize = u16(cursor + 32)
            let next = cursor + 46 + nameSize + extraSize + commentSize
            guard next <= centralEnd else { throw Failure.invalidArchive }
            defer { cursor = next }
            guard let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameSize)], encoding: .utf8) else { continue }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"),
                  MFiIdentityFiles.names.contains(parts[2]) else { continue }
            guard !parts.contains(".."), !parts.contains("."), !name.contains("\\"),
                  u16(cursor + 8) & 1 == 0, u16(cursor + 34) == 0,
                  u32(cursor + 20) != .max, u32(cursor + 24) != .max, u32(cursor + 42) != .max,
                  (u32(cursor + 38) >> 16) & 0xf000 != 0xa000 else { throw Failure.invalidEntry }
            let entry = Entry(name: name, method: u16(cursor + 10), crc: u32(cursor + 16),
                compressed: Int(u32(cursor + 20)), expanded: Int(u32(cursor + 24)), offset: Int(u32(cursor + 42)))
            guard (1...65_536).contains(entry.expanded), (1...131_072).contains(entry.compressed) else { throw Failure.invalidEntry }
            guard groups[parts[1]]?[parts[2]] == nil else { throw Failure.ambiguousIdentity }
            groups[parts[1], default: [:]][parts[2]] = entry
        }
        guard cursor == centralEnd else { throw Failure.invalidArchive }
        let complete = groups.values.filter { Set($0.keys) == MFiIdentityFiles.names }
        guard complete.count == 1 else { throw complete.isEmpty ? Failure.missingFiles : Failure.ambiguousIdentity }
        var files: [String: Data] = [:]
        for (name, entry) in complete[0] {
            let offset = entry.offset
            guard offset + 30 <= centralStart, u32(offset) == 0x04034b50,
                  u16(offset + 6) & 1 == 0, u16(offset + 8) == entry.method else { throw Failure.invalidEntry }
            let nameSize = u16(offset + 26), extraSize = u16(offset + 28)
            let start = offset + 30 + nameSize + extraSize
            guard start + entry.compressed <= centralStart,
                  String(bytes: bytes[(offset + 30)..<(offset + 30 + nameSize)], encoding: .utf8) == entry.name else {
                throw Failure.invalidEntry
            }
            let compressed = Array(bytes[start..<(start + entry.compressed)])
            let output: [UInt8]
            switch entry.method {
            case 0:
                guard compressed.count == entry.expanded else { throw Failure.invalidEntry }
                output = compressed
            case 8:
                // Apple's ZLIB algorithm decodes raw DEFLATE, as used by ZIP.
                // One spare byte ensures an overstated decompression stream is rejected.
                var buffer = [UInt8](repeating: 0, count: entry.expanded + 1)
                let count = buffer.withUnsafeMutableBufferPointer { destination in
                    compressed.withUnsafeBufferPointer { source in
                        compression_decode_buffer(destination.baseAddress!, destination.count,
                            source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
                    }
                }
                guard count == entry.expanded else { throw Failure.invalidEntry }
                output = Array(buffer.prefix(count))
            default: throw Failure.unsupportedArchive
            }
            guard crc32(output) == entry.crc else { throw Failure.invalidEntry }
            files[name] = Data(output)
        }
        return try MFiIdentityFiles(files: files)
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        let crc = bytes.reduce(UInt32.max) { result, byte in
            var value = result ^ UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
            return value
        }
        return ~crc
    }
}
