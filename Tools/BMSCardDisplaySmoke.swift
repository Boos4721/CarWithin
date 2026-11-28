import CoreGraphics
import CoreImage
import Foundation
import ImageIO

@main
struct BMSCardDisplaySmoke {
    static func main() throws {
        var reading = ANTBMSReading(voltage: 82.78, current: -12.3, power: -1018, stateOfCharge: 78,
            stateOfHealth: nil, stateCode: 2, capacityAh: 170, remainingAh: 131.92,
            cells: [4.100, 4.106], temperatures: [24], mosTemperature: nil, protectionBits: 0, warningBits: 0)
        reading.family = .dl
        let directory = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var classic = ANTBMSCardConfiguration()
        let old = try require(BMSCardRenderer.render(reading, configuration: classic))
        precondition(old.width == 640 && old.height == 122)
        try save(old, "classic", in: directory)
        print("PASS: production renderer preserves classic two-line dimensions")
        for scene in ANTBMSCardConfiguration.Scene.allCases {
            var card = classic; card.apply(scene)
            let image = try require(BMSCardRenderer.render(reading, configuration: card))
            precondition(image.width == 640 && image.height >= 176)
            try save(image, scene.rawValue, in: directory)
            for (width, height) in [(480,272),(848,480),(1024,600),(800,480),(1600,770),(2048,968)] {
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                let background = CIImage(color: CIColor(red: 0.08, green: 0.12, blue: 0.18)).cropped(to: bounds)
                let composed = BMSVideoCompositor.composite(CIImage(cgImage: image), configuration: card, over: background, in: bounds)
                let result = try require(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(composed, from: bounds))
                precondition(result.width == width && result.height == height)
                if width == 480 { try save(result, "ninebot43-" + scene.rawValue, in: directory) }
            }
        }
        print("PASS: all three scene cards render through real Core Image on Ninebot and ZEEHO canvases")
        classic.style = .prominent
        var sparse = reading; sparse.available = []; sparse.reportedCellDelta = nil
        sparse = ANTBMSReading(voltage: 0, current: 0, power: 0, stateOfCharge: 0, stateOfHealth: nil, stateCode: 0,
            capacityAh: 0, remainingAh: 0, cells: [], temperatures: [], mosTemperature: nil, protectionBits: 0, warningBits: 0)
        sparse.available = []
        precondition(ANTBMSCardConfiguration.Field.charge.displayMetric(sparse).value == "--")
        precondition(ANTBMSCardConfiguration.Field.power.displayMetric(sparse).value == "--")
        precondition(ANTBMSCardConfiguration.Field.charge.displayMetric(reading).value == "78")
        try save(try require(BMSCardRenderer.render(sparse, configuration: classic)), "missing-fields", in: directory)
        let compact = try require(BMSCardRenderer.render(nil, configuration: classic))
        precondition(compact.height == 64)
        try save(compact, "disconnected", in: directory)
        classic.lossDisplay = .hidden
        precondition(BMSCardRenderer.render(nil, configuration: classic) == nil)
        precondition(BMSCardRenderer.render(reading, configuration: classic) != nil)
        print("PASS: missing values stay unknown; disconnected card shrinks or hides and fresh data returns")
        // Move a solid marker to a custom coordinate and verify the actual Core Image result.
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 272)
        let marker = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 176))
        classic.customAnchor = .init(x: 0.25, y: 0.75)
        let frame = classic.overlayFrame(in: bounds, imageSize: marker.extent.size)
        let canvas = BMSVideoCompositor.composite(marker, configuration: classic,
            over: CIImage(color: .black).cropped(to: bounds), in: bounds)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(canvas, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: frame.midX, y: bounds.maxY - frame.midY, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        precondition(pixel[0] > 240 && pixel[1] < 10 && pixel[2] < 10)
        print("PASS: custom top-left preview placement matches bottom-left video coordinates")
    }
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "BMSCardDisplaySmoke", code: 1) }; return value
    }
    static func save(_ image: CGImage, _ name: String, in directory: URL?) throws {
        guard let directory else { return }
        let url = directory.appendingPathComponent(name + ".png")
        let destination = try require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
}
