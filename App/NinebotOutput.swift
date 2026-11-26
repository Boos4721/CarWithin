import CoreImage
import Foundation
import ImageIO
import VideoToolbox

/// Runs codecs and UDP writes off the CarPlay receive queue.
final class NinebotOutput {
    static let width = 848
    static let height = 480
    static let fps = 30
    static let sevenInchFormat = (width: 1024, height: 600, fps: 25)
    static let fourThreeFormat = (width: 480, height: 272, fps: 10)

    enum Mode {
        case fiveInch, sevenInch, fourThreeInch
    }

    private let queue = DispatchQueue(label: "CarWithin.ninebot", qos: .userInitiated)
    private var session: Session?
    private var bmsImage: CGImage?
    private var bmsConfiguration = ANTBMSCardConfiguration()

    func setBMSOverlay(_ image: CGImage?, configuration: ANTBMSCardConfiguration) {
        bmsImage = image; bmsConfiguration = configuration
        let current = session
        queue.async { current?.setBMSOverlay(image, configuration: configuration) }
    }

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, mode: Mode, onState: @escaping (String) -> Void, onPhase: @escaping (InstrumentChannelPhase) -> Void,
               onLog: @escaping (String) -> Void, requestKeyframe: @escaping () -> Void,
               onPrepared: @escaping (Result<Void, Error>) -> Void) {
        stop()
        let next = Session(queue: queue, mode: mode, onState: onState, onPhase: onPhase, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        let overlay = bmsImage, configuration = bmsConfiguration
        queue.async {
            next.setBMSOverlay(overlay, configuration: configuration)
            next.start(localAddress, targetAddress, onPrepared: onPrepared)
        }
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
        let mode: Mode
        var sevenInch: Bool { mode == .sevenInch }
        var usesJPEG: Bool { mode == .fourThreeInch }
        private var kcp: NinebotKCPVideo?
        let onState: (String) -> Void
        let onPhase: (InstrumentChannelPhase) -> Void
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

        private var timer: DispatchSourceTimer?
        private var channels: NinebotUDPChannels?
        private var video: NinebotUDPSocket? { channels?.video }
        private var control: NinebotUDPSocket? { channels?.control }
        private var startupRetry: DispatchWorkItem?
        private var startupDeadline = 0.0
        private var startupCompletion: ((Result<Void, Error>) -> Void)?
        private var waitingForPorts = false
        private var localAddress = ""
        private var targetAddress = ""
        private var networkRecoverySince: Double?
        private var networkRecoveryError: Error?
        private var nextNetworkRecoveryAttempt = 0.0
        private let packetizer = NinebotH264Packetizer()
        private lazy var jpegPacketizer = NinebotJPEGPacketizer()
        private var jpegTimestamp: UInt32 = 0
        private var jpegFramesSent = 0
        private var jpegFramesDropped = 0
        private var lastJPEGReport = 0.0
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private let canvas = InstrumentVideoCanvas()
        private var fresh = false
        private let origin = ProcessInfo.processInfo.systemUptime
        private var lastFrame = -Double.infinity
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var nextHeartbeat = 0.0
        private var counter: UInt32 = 0
        private var lastReply: Double?
        private var sentPicture = false
        private var acknowledgedVideo = false
        private var nextVideoFrame = 0.0
        private var status = ""

        func setBMSOverlay(_ image: CGImage?, configuration: ANTBMSCardConfiguration) {
            canvas.setBMSOverlay(image, configuration: configuration)
            fresh = true
        }

        init(queue: DispatchQueue, mode: Mode, onState: @escaping (String) -> Void, onPhase: @escaping (InstrumentChannelPhase) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.mode = mode
            if mode == .fourThreeInch { counter = .max }
            self.onState = onState
            self.onPhase = onPhase
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
        }

        func start(_ local: String, _ target: String, onPrepared: @escaping (Result<Void, Error>) -> Void) {
            guard active else { return }
            localAddress = local; targetAddress = target
            startupDeadline = ProcessInfo.processInfo.systemUptime + 10
            startupCompletion = onPrepared
            prepareChannels()
        }

        private func prepareChannels() {
            startupRetry = nil
            guard active, startupCompletion != nil else { return }
            do {
                // Keep partial binds local until both ports and the first send succeed.
                let channels = try NinebotUDPChannels(localIP: localAddress, remoteIP: targetAddress)
                // Prepare both sockets and send the first control packet before starting CarPlay.
                // Local send success is not an acknowledgement that projection is enabled remotely.
                counter &+= 1
                let heartbeat = usesJPEG ? NinebotJPEGPacketizer.heartbeat(counter: counter)
                                         : NinebotH264Packetizer.heartbeat(counter: counter)
                try channels.control.send(heartbeat)
                nextHeartbeat = ProcessInfo.processInfo.systemUptime + 1
                guard active else { channels.close(); close(); return }
                self.channels = channels
                if waitingForPorts { onLog("本机投屏端口已释放，继续启动 CarPlay") }
                waitingForPorts = false
                onLog("九号投屏端口 5012/5013 已就绪，已发送首个控制握手")
                report("投屏通道已准备，等待仪表回应…", phase: .ready)
                switch mode {
                case .fourThreeInch: onLog("九号 4.3 寸：JPEG/RTP UDP 5012 · RTCP UDP 5013 · 480×272 · 最高 10 FPS")
                case .sevenInch: onLog("九号 7 寸：KCP/UDP 5012 · RTCP/UDP 5013 · 1024×600 · H.264 Baseline 3.1 · 25 FPS")
                case .fiveInch: onLog("九号 5 寸：UDP 5012/5013 · 848×480 · H.264 Baseline · 30 FPS")
                }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(sevenInch ? 10 : usesJPEG ? 20 : 33), leeway: .milliseconds(3))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
                let completion = startupCompletion; startupCompletion = nil
                completion?(.success(()))
            } catch let error as NinebotSocketError where error.isPortInUse && ProcessInfo.processInfo.systemUptime < startupDeadline {
                guard active else { close(); return }
                if !waitingForPorts {
                    waitingForPorts = true
                    onLog("本机投屏端口被占用，最多等待 10 秒释放。请结束九号出行导航投屏，必要时关闭其后台实例。")
                }
                report("投屏端口被占用，正在等待释放；请结束九号出行导航投屏…", phase: .waitingForPorts)
                let retry = DispatchWorkItem { [weak self] in self?.prepareChannels() }
                startupRetry = retry
                queue.asyncAfter(deadline: .now() + 0.5, execute: retry)
            } catch {
                guard active else { close(); return }
                let completion = startupCompletion; startupCompletion = nil
                fail(error)
                completion?(.failure(error))
            }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() { lock.withLock { cancelled = true } }

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
                    // Throttle rebuilds while VideoToolbox is unavailable during a lock transition.
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
                if let image { latest = image; fresh = true }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        private func tick() {
            guard active else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if networkRecoverySince != nil { recoverNetwork(at: now); return }
            guard let video, let control else { return }
            do {
                if now >= nextHeartbeat {
                    nextHeartbeat = now + 1
                    counter &+= 1
                    let heartbeat = usesJPEG ? NinebotJPEGPacketizer.heartbeat(counter: counter)
                                           : NinebotH264Packetizer.heartbeat(counter: counter)
                    do { try control.send(heartbeat) }
                    catch let error as NinebotSocketError where error.isTransient {}
                }
                for _ in 0..<8 {
                    guard let response = try control.receive() else { break }
                    if sevenInch, let reply = NinebotH264Packetizer.sevenInchHeartbeatReply(response), counter &- reply.counter < 8 {
                        lastReply = now
                        if kcp == nil {
                            kcp = try NinebotKCPVideo(socket: video, conversation: reply.conversation)
                            onLog("九号 7 寸已协商 KCP 会话号：\(reply.conversation)")
                        }
                    } else if !sevenInch, let reply = NinebotH264Packetizer.heartbeatReplyCounter(response), counter &- reply < 8 {
                        if usesJPEG, lastReply.map({ now - $0 >= 4 }) ?? true {
                            onLog("九号 4.3 寸收到 RTCP 回应 #\(reply)")
                        }
                        lastReply = now
                    }
                }
                if let lastReply, now - lastReply < 4 {
                    if sevenInch, !acknowledgedVideo {
                        report(sentPicture ? "等待仪表确认视频数据…" : "仪表已回应，等待发送画面…", phase: .responding)
                    } else {
                        report(sevenInch ? "仪表已确认收到数据，正在发送画面" :
                               sentPicture ? "仪表已回应，正在发送画面" : "仪表已回应，等待发送画面…", phase: sentPicture ? .sending : .responding)
                    }
                } else if now - origin > 4 {
                    report("未收到仪表回应，请检查 Wi-Fi 和仪表 IP。", phase: .ready)
                }
                if usesJPEG {
                    try sendJPEGFrame(to: video, at: now)
                    return
                }
                if sevenInch {
                    guard let kcp else { return }
                    if try kcp.poll(at: now), !acknowledgedVideo {
                        acknowledgedVideo = true
                        onLog("九号 7 寸仪表已确认收到 KCP 视频数据")
                    }
                    guard kcp.canAcceptFrame, now >= nextVideoFrame else { return }
                }
                guard let latest, fresh || now - lastFrame >= 0.5 else { return }
                if sevenInch {
                    let interval = 1 / Double(NinebotOutput.sevenInchFormat.fps)
                    nextVideoFrame = max(nextVideoFrame, now - interval / 2) + interval
                }
                lastFrame = now
                fresh = false
                guard let frame = encode(latest, at: now) else { return }
                let timestamp = UInt32(truncatingIfNeeded: Int64(now * 1_000))
                let packets = packetizer.packets(for: frame.data, timestampMilliseconds: timestamp,
                                                isKeyframe: frame.isKeyframe, repeatKeyframe: false)
                do {
                    if sevenInch {
                        guard let kcp, try kcp.enqueueFrame(packets) else { lastKeyframe = -.infinity; return }
                        sentPicture = true
                        if frame.isKeyframe { lastKeyframe = now }
                        return
                    }
                    for (index, packet) in packets.enumerated() {
                        guard active else { return }
                        try video.send(packet)
                        if packets.count > 12, index + 1 < packets.count, (index + 1).isMultiple(of: 8) {
                            usleep(750)
                        }
                    }
                    sentPicture = true
                    if frame.isKeyframe { lastKeyframe = now }
                } catch let error as NinebotSocketError where error.isTransient {
                    lastKeyframe = -.infinity
                }
            } catch let error as NinebotSocketError where error.isNetworkUnavailable {
                networkRecoverySince = now
                networkRecoveryError = error
                nextNetworkRecoveryAttempt = now + 0.5
                channels?.close(); channels = nil; kcp = nil
                lastReply = nil; acknowledgedVideo = false; sentPicture = false
                onLog("九号 Wi-Fi 暂不可用，最多等待 8 秒恢复投屏通道：\(error.localizedDescription)")
                report("Wi-Fi 暂时中断，正在恢复投屏通道…", phase: .recovering)
            } catch { fail(error) }
        }

        private func recoverNetwork(at now: Double) {
            guard let since = networkRecoverySince else { return }
            guard now - since < 8 else {
                fail(networkRecoveryError ?? ConfigurationError("仪表 Wi-Fi 8 秒内未恢复，请重新连接"))
                return
            }
            guard now >= nextNetworkRecoveryAttempt else { return }
            nextNetworkRecoveryAttempt = now + 0.5
            // A different address is handled by the controller's startup monitor.
            guard ReceiverConfiguration.wifiIPv4Address() == localAddress else { return }
            do {
                let channels = try NinebotUDPChannels(localIP: localAddress, remoteIP: targetAddress)
                counter &+= 1
                let heartbeat = usesJPEG ? NinebotJPEGPacketizer.heartbeat(counter: counter)
                                         : NinebotH264Packetizer.heartbeat(counter: counter)
                try channels.control.send(heartbeat)
                guard active else { return }
                self.channels = channels
                networkRecoverySince = nil; networkRecoveryError = nil
                nextHeartbeat = now + 1
                fresh = true; lastKeyframe = -.infinity
                onLog("九号 Wi-Fi 已恢复，已重建 UDP 5012/5013 通道并重新发送握手")
                report("投屏通道已恢复，等待仪表回应…", phase: .ready)
                requestKeyframe()
            } catch let error as NinebotSocketError where error.isNetworkUnavailable || error.isTransient || error.isPortInUse {
                networkRecoveryError = error
            } catch { fail(error) }
        }

        private func sendJPEGFrame(to video: NinebotUDPSocket, at now: Double) throws {
            let format = NinebotOutput.fourThreeFormat
            guard let latest, now >= nextVideoFrame, fresh || now - lastFrame >= 0.5 else { return }
            let interval = 1 / Double(format.fps)
            nextVideoFrame = max(nextVideoFrame, now - interval / 2) + interval
            lastFrame = now
            let bounds = CGRect(x: 0, y: 0, width: format.width, height: format.height)
            guard let jpeg = canvas.jpeg(latest, in: bounds, refresh: fresh) else {
                logCodecFailure(" JPEG 编码", ConfigurationError("无法生成九号 4.3 寸画面"))
                return
            }
            fresh = false
            jpegTimestamp = UInt32(truncatingIfNeeded: Self.unixMilliseconds)
            let packets = try jpegPacketizer.packets(for: jpeg, timestamp: jpegTimestamp)
            do {
                for packet in packets {
                    guard active else { return }
                    try video.send(packet)
                }
                sentPicture = true
                jpegFramesSent += 1
            } catch let error as NinebotSocketError where error.isTransient {
                jpegFramesDropped += 1
            }
            if now - lastJPEGReport >= 5 {
                lastJPEGReport = now
                onLog("九号 4.3 寸 JPEG：已发送 \(jpegFramesSent) 帧，发送丢弃 \(jpegFramesDropped) 帧，当前 \(jpeg.count) 字节")
            }
        }

        private static var unixMilliseconds: UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000) }

        private func encode(_ image: CVPixelBuffer, at now: Double) -> H264EncodedFrame? {
            do {
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    let format = sevenInch ? NinebotOutput.sevenInchFormat : (NinebotOutput.width, NinebotOutput.height, NinebotOutput.fps)
                    encoder = try H264Encoder(width: format.0, height: format.1, fps: format.2, bitrate: sevenInch ? 2_000_000 : 1_500_000,
                                              profileLevel: sevenInch ? kVTProfileLevel_H264_Baseline_3_1 : kVTProfileLevel_H264_Baseline_AutoLevel) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                let format = sevenInch ? NinebotOutput.sevenInchFormat : (NinebotOutput.width, NinebotOutput.height, NinebotOutput.fps)
                try encoder.encode(try canvas.fittedImage(image, width: format.0, height: format.1), presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
                                   forceKeyframe: now - lastKeyframe >= 0.5)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                return try result?.get()
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lock.withLock { encoded = nil }
                logCodecFailure("编码", error)
                return nil
            }
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog("九号\(stage)恢复：\(error.localizedDescription)") }
            lastCodecFailure = now
        }

        private func report(_ message: String, phase: InstrumentChannelPhase) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onPhase(phase)
                self.onState(message)
            }
        }

        private func fail(_ error: Error) {
            let message = "九号输出失败：\(error.localizedDescription)"
            onLog(message)
            report(message, phase: .failed)
            close()
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            startupRetry?.cancel(); startupRetry = nil; startupCompletion = nil
            timer?.cancel()
            timer = nil
            if usesJPEG {
                try? control?.send(jpegPacketizer.bye(timestamp: jpegTimestamp, unixMilliseconds: Self.unixMilliseconds))
            } else {
                try? control?.send(NinebotH264Packetizer.bye)
            }
            // Close descriptors explicitly before releasing KCP/codec objects that can retain them.
            channels?.close(); channels = nil
            kcp = nil
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
            canvas.setBMSOverlay(nil, configuration: ANTBMSCardConfiguration())
        }
    }
}
