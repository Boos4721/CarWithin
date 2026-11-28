import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Shared canvas for Ninebot JPEG and Ninebot/ZEEHO H.264 outputs. Used only on the output queue.
final class InstrumentVideoCanvas {
    private var bmsOverlay: CIImage?
    private var bmsConfiguration = ANTBMSCardConfiguration()
    private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private var cachedJPEG: Data?
    private var cachedBounds: CGRect?

    func setBMSOverlay(_ image: CGImage?, configuration: ANTBMSCardConfiguration) {
        bmsOverlay = image.map { CIImage(cgImage: $0) }
        bmsConfiguration = configuration
        cachedJPEG = nil
    }

    func jpeg(_ image: CVPixelBuffer, in bounds: CGRect, refresh: Bool) -> Data? {
        if refresh || cachedJPEG == nil || cachedBounds != bounds {
            cachedJPEG = compositor.jpegRepresentation(of: fittedCanvas(image, in: bounds),
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
            cachedBounds = bounds
        }
        return cachedJPEG
    }

    private enum CanvasError: LocalizedError {
        case allocation(CVReturn)
        var errorDescription: String? {
            switch self { case .allocation(let status): "无法分配仪表缩放画面（\(status)）" }
        }
    }

    func fittedImage(_ image: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        if bmsOverlay == nil, CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw CanvasError.allocation(status) }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        compositor.render(fittedCanvas(image, in: bounds), to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    func fittedCanvas(_ image: CVPixelBuffer, in bounds: CGRect) -> CIImage {
        let source = CIImage(cvPixelBuffer: image)
        let scale = min(bounds.width / source.extent.width, bounds.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: (bounds.width - scaled.extent.width) / 2,
            y: (bounds.height - scaled.extent.height) / 2))
        let canvas = positioned.composited(over: CIImage(color: .black)).cropped(to: bounds)
        guard let bmsOverlay else { return canvas }
        return BMSVideoCompositor.composite(bmsOverlay, configuration: bmsConfiguration, over: canvas, in: bounds)
    }
}

/// Core Image uses bottom-left coordinates; the shared configuration returns a top-left frame.
enum BMSVideoCompositor {
    static func composite(_ overlay: CIImage?, configuration: ANTBMSCardConfiguration,
                          over canvas: CIImage, in bounds: CGRect) -> CIImage {
        guard let overlay else { return canvas }
        let frame = configuration.overlayFrame(in: bounds, imageSize: overlay.extent.size)
        guard frame.width > 0, frame.height > 0 else { return canvas }
        let normalized = overlay.transformed(by: CGAffineTransform(translationX: -overlay.extent.minX, y: -overlay.extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: frame.width / overlay.extent.width,
                                                                  y: frame.height / overlay.extent.height))
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: frame.minX,
            y: bounds.maxY - (frame.maxY - bounds.minY)))
        return positioned.composited(over: canvas).cropped(to: bounds)
    }
}
