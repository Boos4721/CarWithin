import Foundation

func cfmotoNegotiationSmoke() throws {
    func body(_ width: UInt16, _ height: UInt16, _ fps: UInt32 = 30, _ codec: UInt32 = 2) -> Data {
        var data = Data(); data.appendLE(width); data.appendLE(height); data.appendLE(fps); data.appendLE(codec); return data
    }
    let five = try PxcConnection.validatedMediaSize(body(800, 386))
    precondition(five.width == 800 && five.height == 386 && five.fps == 30)
    let six = try PxcConnection.validatedMediaSize(body(1024, 515))
    precondition(six.width == 1024 && six.height == 516)
    // 2026-11-26 改动（对齐极核 AE2）：编码值不再是拒绝理由，
    // codec=3 等非 0/2 值也按 H.264 接受，只验尺寸和帧率。
    let otherCodec = try PxcConnection.validatedMediaSize(body(800, 386, 25, 3))
    precondition(otherCodec.width == 800 && otherCodec.height == 386 && otherCodec.fps == 25)
    // 2026-11-26 实车抓包确认春风 5 寸仪表会报 800×386@0 编码器=2，fps=0 需兜底为 25 FPS。
    let zeroFps = try PxcConnection.validatedMediaSize(body(800, 386, 0, 2))
    precondition(zeroFps.width == 800 && zeroFps.height == 386 && zeroFps.fps == 25)
    for invalid in [Data(), body(0, 480), body(65535, 480), body(800, 0), body(800, 480, 61)] {
        do { _ = try PxcConnection.validatedMediaSize(invalid); fatalError("Accepted invalid PXC media configuration") }
        catch TailingError.protocolFailure { }
    }
    print("PASS: 春风媒体配置长度、尺寸、帧率边界与偶数对齐")
}
