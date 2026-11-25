import Darwin
import Foundation

/// Exercises real Darwin UDP port ownership without a vehicle or simulator.
@main
enum NinebotSocketSmoke {
    static func reserve() throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure.check("reserve socket") }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            precondition(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { throw Failure.check("reserve bind") }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0 else { throw Failure.check("reserve getsockname") }
            return (fd, UInt16(bigEndian: address.sin_port))
        } catch { Darwin.close(fd); throw error }
    }
    static func occupied(_ port: UInt16, _ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.check("occupied port unexpectedly succeeded") }
        catch let error as NinebotSocketError {
            guard case .portInUse(let ip, let actual) = error, ip == "127.0.0.1", actual == port,
                  error.isPortInUse, !error.isTransient, !error.isNetworkUnavailable else {
                throw Failure.check("wrong occupied-port error: \(error)")
            }
            precondition(error.localizedDescription.contains("九号出行"))
        }
    }
    enum Failure: Error { case check(String) }
    static func main() throws {
        let (videoBlocker, videoPort) = try reserve()
        let (controlBlocker, controlPort) = try reserve()
        var ownsVideoBlocker = true, ownsControlBlocker = true
        defer {
            if ownsVideoBlocker { Darwin.close(videoBlocker) }
            if ownsControlBlocker { Darwin.close(controlBlocker) }
        }
        func pair() throws -> NinebotUDPChannels {
            try NinebotUDPChannels(localIP: "127.0.0.1", remoteIP: "127.0.0.2", videoPort: videoPort, controlPort: controlPort)
        }
        try occupied(videoPort) { _ = try pair() }
        print("PASS: another process-style exclusive video bind reports port conflict")
        Darwin.close(videoBlocker); ownsVideoBlocker = false
        try occupied(controlPort) { _ = try pair() }
        let videoProbe = try NinebotUDPSocket(localIP: "127.0.0.1", localPort: videoPort, remoteIP: "127.0.0.2", remotePort: videoPort)
        videoProbe.close()
        print("PASS: busy control port rolls back partially bound video socket")
        Darwin.close(controlBlocker); ownsControlBlocker = false
        let ready = try pair()
        try occupied(videoPort) { _ = try pair() }
        let retainedVideo = ready.video, retainedControl = ready.control
        ready.close(); ready.close()
        let replacement = try pair()
        for socket in [retainedVideo, retainedControl] {
            do { try socket.send(Data([1])); throw Failure.check("closed socket sent data") }
            catch NinebotSocketError.closed {}
        }
        replacement.close()
        print("PASS: explicit close releases ports despite retained socket references; close is idempotent")
        for _ in 0..<100 { let next = try pair(); next.close() }
        print("PASS: 100 immediate stop/start port handoffs")
        do {
            _ = try NinebotUDPSocket(localIP: "127.0.0.1", localPort: videoPort, remoteIP: "invalid", remotePort: videoPort)
            throw Failure.check("invalid remote address accepted")
        } catch NinebotSocketError.invalidAddress {}
        let afterFailure = try pair(); afterFailure.close()
        print("PASS: failed initialization releases its bound descriptor")
    }
}
