import CoreImage
import Foundation
import VideoToolbox

/// 春风 / MotoPlay 仪表的输出规格。分辨率取仪表实际像素；编码时按偶数对齐
/// （H.264 4:2:0 要求宽高为偶数，1024×515 会按 1024×516 编码）。
struct CfmotoProfile: Equatable {
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int

    static let defaultPort: UInt16 = 21000
    static let fiveInch = CfmotoProfile(width: 800, height: 386, fps: 30, bitrate: 3_500_000)
    static let sixInch = CfmotoProfile(width: 1024, height: 515, fps: 30, bitrate: 4_500_000)

    var encodeWidth: Int { width - width % 2 }
    var encodeHeight: Int { height % 2 == 0 ? height : height + 1 }
    var title: String { "\(width)×\(height)" }
}

/// 把 CarPlay 的 H.264 画面重新编码成仪表规格，再按帧推到一个 UDP 端口。
/// 与极核/九号不同，这里没有仪表拉帧的握手：起点是「App 直推」，
/// 仪表侧协议对不上时只会黑屏，不会影响本机 CarPlay 显示。
final class CfmotoOutput {
    private let queue: DispatchQueue
    private var session: Session?

    init(name: String = "cfmoto") {
        queue = DispatchQueue(label: "CarWithin.\(name)", qos: .userInitiated)
    }

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, port: UInt16, profile: CfmotoProfile,
               mode: CfmotoUDPChannel.Mode = .rtp,
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, localAddress: localAddress, targetAddress: targetAddress,
                           port: port, profile: profile, mode: mode,
                           onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
    }

    func stop() {
        guard let previous = session else { return }
        session = nil
        previous.cancel()
        queue.async { previous.close() }
    }

    private final class Session: @unchecked Sendable {
        let queue: DispatchQueue
        let profile: CfmotoProfile
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?

        private let localAddress: String
        private let targetAddress: String
        private let port: UInt16
        private let mode: CfmotoUDPChannel.Mode
        private var channel: CfmotoUDPChannel?
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var status = ""

        init(queue: DispatchQueue, localAddress: String, targetAddress: String, port: UInt16,
             profile: CfmotoProfile, mode: CfmotoUDPChannel.Mode,
             onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.profile = profile
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
            self.localAddress = localAddress
            self.targetAddress = targetAddress
            self.port = port
            self.mode = mode
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func start() {
            report("正在推流到春风仪表 \(profile.title) · UDP")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var first = true
                var nextFrame = ProcessInfo.processInfo.systemUptime
                do {
                    channel = try CfmotoUDPChannel(localIP: localAddress, targetIP: targetAddress,
                                                   port: port, fps: profile.fps, mode: mode)
                    while active {
                        let ready = queue.sync { latest != nil }
                        if !ready { Thread.sleep(forTimeInterval: 0.02); continue }
                        let remaining = nextFrame - ProcessInfo.processInfo.systemUptime
                        if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 0.04)); continue }
                        nextFrame = ProcessInfo.processInfo.systemUptime + 1.0 / Double(profile.fps)
                        let result = queue.sync { () -> H264EncodedFrame? in
                            guard active, let image = latest else { return nil }
                            return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: first)
                        }
                        guard let result else {
                            // 编码器刚重建时先等一帧，避免把时间片空转掉。
                            Thread.sleep(forTimeInterval: 0.03)
                            continue
                        }
                        try channel?.send(accessUnit: result.data, keyframe: result.isKeyframe)
                        first = false
                        report("正在投屏 · \(profile.title) · H.264 · UDP")
                    }
                } catch {
                    if active {
                        onLog("春风输出失败：\(error.localizedDescription)")
                        report("春风连接失败：\(error.localizedDescription)")
                    }
                }
                channel?.close()
                queue.async { [self] in close() }
            }
        }

        func cancel() {
            lock.withLock { cancelled = true }
            channel?.close()
        }

        func append(_ data: Data, keyframe: Bool) {
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= 6 {
                    let request = !skipping
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1 } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                decode(data, keyframe: keyframe)
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else { picture.append(unit) }
                }
                if waitingForIDR {
                    guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                        requestKeyframe()
                        return
                    }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] image in
                            guard let self else { return }
                            self.lock.withLock { self.decoded = image }
                        }, failure: { [weak self] error in
                            guard let self else { return }
                            self.lock.withLock { self.decodeError = error }
                        })
                    waitingForIDR = false
                }
                guard let decoder, !picture.isEmpty else { return }
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                decoder.waitForFrames()
                let (image, error) = lock.withLock {
                    defer { decoded = nil; decodeError = nil }
                    return (decoded, decodeError)
                }
                if let error { throw error }
                if let image { latest = image }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        private func encode(_ image: CVPixelBuffer, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            do {
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    encoder = try H264Encoder(width: profile.encodeWidth, height: profile.encodeHeight,
                                              fps: profile.fps, bitrate: profile.bitrate) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                try encoder.encode(try fittedImage(image),
                                   presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
                                   forceKeyframe: forceKeyframe || lastKeyframe == -.infinity)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                let frame = try result?.get()
                if frame?.isKeyframe == true { lastKeyframe = now }
                return frame
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lastKeyframe = -.infinity
                lock.withLock { encoded = nil }
                logCodecFailure("编码", error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = profile.encodeWidth, height = profile.encodeHeight
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw ConfigurationError("无法分配春风缩放画面（\(status)）")
            }
            let source = CIImage(cvPixelBuffer: image)
            let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                              to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog("春风\(stage)恢复：\(error.localizedDescription)") }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            channel?.close()
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
        }
    }
}
