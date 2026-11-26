import CoreImage
import CoreVideo
import Foundation
import ImageIO

@main
struct NinebotCanvasSmoke {
    static let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    static let bounds = CGRect(x: 0, y: 0, width: 480, height: 272)

    static func main() throws {
        let source = try buffer(width: 960, height: 544)
        let renderer = NinebotVideoCanvas()
        let red = try overlay(CIColor(red: 1, green: 0, blue: 0))
        let green = try overlay(CIColor(red: 0, green: 1, blue: 0))
        var config = ANTBMSCardConfiguration()
        for position in ANTBMSCardConfiguration.Position.allCases {
            config.position = position
            renderer.setBMSOverlay(red, configuration: config)
            let jpeg = try required(renderer.jpeg(source, in: bounds, refresh: false))
            let image = try decoded(jpeg)
            precondition(image.extent.width == 480 && image.extent.height == 272)
            let x: CGFloat = position.isAtRight ? 420 : 60
            let y: CGFloat = position.isAtTop ? 252 : 20
            try expectColor(image, at: CGPoint(x: x, y: y), channel: 0)
            try expectColor(image, at: CGPoint(x: 240, y: 136), channel: 2)
        }
        print("PASS: 4.3-inch JPEG contains the overlay in all four corners, preserves 480x272 and the background")

        config.position = .topRight
        renderer.setBMSOverlay(red, configuration: config)
        let first = try required(renderer.jpeg(source, in: bounds, refresh: false))
        let cached = try required(renderer.jpeg(source, in: bounds, refresh: false))
        precondition(first == cached)
        renderer.setBMSOverlay(green, configuration: config)
        let changed = try required(renderer.jpeg(source, in: bounds, refresh: false))
        precondition(first != changed)
        try expectColor(decoded(changed), at: CGPoint(x: 420, y: 252), channel: 1)
        print("PASS: changed BMS data invalidates JPEG cache without a new CarPlay frame")

        config.position = .bottomLeft
        renderer.setBMSOverlay(green, configuration: config)
        let moved = try decoded(required(renderer.jpeg(source, in: bounds, refresh: false)))
        try expectColor(moved, at: CGPoint(x: 60, y: 20), channel: 1)
        try expectColor(moved, at: CGPoint(x: 420, y: 252), channel: 2)
        renderer.setBMSOverlay(nil, configuration: config)
        let disabled = try decoded(required(renderer.jpeg(source, in: bounds, refresh: false)))
        try expectColor(disabled, at: CGPoint(x: 60, y: 20), channel: 2)
        print("PASS: moving and disabling BMS clear the old card on a static frame")

        for (width, height) in [(848, 480), (1024, 600)] {
            config.position = .topRight
            renderer.setBMSOverlay(red, configuration: config)
            let fitted = try renderer.fittedImage(source, width: width, height: height)
            precondition(CVPixelBufferGetWidth(fitted) == width && CVPixelBufferGetHeight(fitted) == height)
            try expectColor(CIImage(cvPixelBuffer: fitted), at: CGPoint(x: width - 60, y: height - 20), channel: 0)
        }
        print("PASS: 5/7-inch H.264 input canvases retain the same card composition")

        renderer.setBMSOverlay(nil, configuration: config)
        let sameSize = try buffer(width: 848, height: 480)
        let unchanged = try renderer.fittedImage(sameSize, width: 848, height: 480)
        precondition(unchanged === sameSize)
        let resizedJPEG = try decoded(required(renderer.jpeg(source, in: CGRect(x: 0, y: 0, width: 240, height: 136), refresh: false)))
        precondition(resizedJPEG.extent.width == 240 && resizedJPEG.extent.height == 136)
        print("PASS: no-overlay fast path and JPEG canvas size changes remain correct")
    }

    static func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess)
        let image = try required(result)
        let area = CGRect(x: 0, y: 0, width: width, height: height)
        context.render(CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: area),
            to: image, bounds: area, colorSpace: CGColorSpaceCreateDeviceRGB())
        return image
    }

    static func overlay(_ color: CIColor) throws -> CGImage {
        let area = CGRect(x: 0, y: 0, width: 640, height: 122)
        return try required(context.createCGImage(CIImage(color: color).cropped(to: area), from: area))
    }
    static func decoded(_ data: Data) throws -> CIImage { try required(CIImage(data: data)) }
    static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "NinebotCanvasSmoke", code: 1) }
        return value
    }
    static func expectColor(_ image: CIImage, at point: CGPoint, channel: Int) throws {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        precondition(pixel[channel] > 170 && (0..<3).filter { $0 != channel }.allSatisfy { pixel[$0] < 90 },
            "Unexpected pixel at \(point): \(pixel), expected channel \(channel)")
    }
}
